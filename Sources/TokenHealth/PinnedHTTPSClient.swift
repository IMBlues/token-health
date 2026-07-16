import CryptoKit
import Foundation
import Network
import Security

struct PinnedHTTPSClient: Sendable {
    enum ClientError: LocalizedError, Sendable {
        case invalidRequest(String)
        case certificateVerificationFailed(String)
        case connectionFailed(String)
        case timedOut
        case invalidResponse(String)
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case let .invalidRequest(message):
                "Invalid pinned HTTPS request: \(message)"
            case let .certificateVerificationFailed(message):
                "TLS certificate pinning failed: \(message)"
            case let .connectionFailed(message):
                "Pinned HTTPS connection failed: \(message)"
            case .timedOut:
                "Pinned HTTPS request timed out"
            case let .invalidResponse(message):
                "Invalid HTTP response: \(message)"
            case .responseTooLarge:
                "Pinned HTTPS response exceeded the size limit"
            }
        }
    }

    private let timeout: TimeInterval
    private let maximumResponseBytes: Int

    init(timeout: TimeInterval = 20, maximumResponseBytes: Int = 4 * 1_024 * 1_024) {
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func data(
        for request: URLRequest,
        pinnedCertificateSHA256: String
    ) async throws -> (Data, HTTPURLResponse) {
        let prepared = try PreparedRequest(
            request: request,
            pinnedCertificateSHA256: pinnedCertificateSHA256
        )
        let verificationState = VerificationState()
        let tlsOptions = makeTLSOptions(
            host: prepared.host,
            fingerprint: prepared.fingerprint,
            verificationState: verificationState
        )
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(
            host: NWEndpoint.Host(prepared.host),
            port: NWEndpoint.Port(rawValue: prepared.port)!,
            using: parameters
        )
        let operation = RequestOperation(
            connection: connection,
            requestData: prepared.serialized,
            responseURL: prepared.url,
            timeout: timeout,
            maximumResponseBytes: maximumResponseBytes,
            verificationState: verificationState
        )
        return try await withTaskCancellationHandler {
            try await operation.run()
        } onCancel: {
            operation.cancel()
        }
    }

    private func makeTLSOptions(
        host: String,
        fingerprint: String,
        verificationState: VerificationState
    ) -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let securityOptions = options.securityProtocolOptions
        sec_protocol_options_set_tls_server_name(securityOptions, host)
        sec_protocol_options_add_tls_application_protocol(securityOptions, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv12)

        let verifyQueue = DispatchQueue(label: "local.token-health.pinned-tls-verify")
        sec_protocol_options_set_verify_block(securityOptions, { _, secTrust, completion in
            let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
            switch CertificateValidator.validate(
                trust: trust,
                expectedHost: host,
                expectedFingerprint: fingerprint
            ) {
            case .success:
                completion(true)
            case let .failure(error):
                verificationState.record(error.localizedDescription)
                completion(false)
            }
        }, verifyQueue)
        return options
    }
}

private struct PreparedRequest {
    let url: URL
    let host: String
    let port: UInt16
    let fingerprint: String
    let serialized: Data

    init(request: URLRequest, pinnedCertificateSHA256: String) throws {
        guard request.httpMethod?.uppercased() == "POST" else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("only POST is supported")
        }
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("the URL must use HTTPS and include a host")
        }
        let portValue = url.port ?? 443
        guard let port = UInt16(exactly: portValue), port > 0 else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("the URL port is invalid")
        }
        guard let fingerprint = Self.normalizedFingerprint(pinnedCertificateSHA256) else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("the certificate SHA-256 must contain 64 hexadecimal characters")
        }

        self.url = url
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
        serialized = try Self.serialize(request: request, url: url, host: host, port: port)
    }

    private static func normalizedFingerprint(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.lowercased().hasPrefix("sha256:") {
            candidate.removeFirst("sha256:".count)
        }
        candidate.removeAll { $0 == ":" || $0.isWhitespace }
        guard candidate.count == 64,
              candidate.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) ||
                  (65...70).contains($0.value) ||
                  (97...102).contains($0.value)
              }) else {
            return nil
        }
        return candidate.lowercased()
    }

    private static func serialize(request: URLRequest, url: URL, host: String, port: UInt16) throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("the URL could not be serialized")
        }
        var target = components.percentEncodedPath
        if target.isEmpty {
            target = "/"
        }
        if let query = components.percentEncodedQuery {
            target += "?\(query)"
        }
        guard !target.contains("\r"), !target.contains("\n") else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("the URL contains an invalid request target")
        }

        let body = request.httpBody ?? Data()
        var headers = request.allHTTPHeaderFields ?? [:]
        for name in headers.keys where
            name.caseInsensitiveCompare("Host") == .orderedSame ||
            name.caseInsensitiveCompare("Content-Length") == .orderedSame ||
            name.caseInsensitiveCompare("Connection") == .orderedSame {
            headers.removeValue(forKey: name)
        }

        let hostHeader: String
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        if port == 443 {
            hostHeader = formattedHost
        } else {
            hostHeader = "\(formattedHost):\(port)"
        }
        headers["Host"] = hostHeader
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"

        var head = "POST \(target) HTTP/1.1\r\n"
        for (name, value) in headers.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            guard !name.isEmpty,
                  !name.contains(":"),
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n") else {
                throw PinnedHTTPSClient.ClientError.invalidRequest("an HTTP header contains invalid characters")
            }
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        guard let headerData = head.data(using: .utf8) else {
            throw PinnedHTTPSClient.ClientError.invalidRequest("the HTTP headers could not be encoded")
        }
        var result = headerData
        result.append(body)
        return result
    }
}

private enum CertificateValidationError: LocalizedError, Sendable {
    case missingTrust
    case fingerprintMismatch
    case propertiesUnavailable
    case hostnameMismatch
    case outsideValidityPeriod
    case serverAuthMissing
    case invalidX509

    var errorDescription: String? {
        switch self {
        case .missingTrust:
            "the server did not provide a certificate"
        case .fingerprintMismatch:
            "the server certificate did not match the configured SHA-256 fingerprint"
        case .propertiesUnavailable:
            "the pinned certificate properties could not be validated"
        case .hostnameMismatch:
            "the pinned certificate did not cover the endpoint host"
        case .outsideValidityPeriod:
            "the pinned certificate is not currently valid"
        case .serverAuthMissing:
            "the pinned certificate is not valid for TLS server authentication"
        case .invalidX509:
            "the pinned certificate failed basic X.509 validation"
        }
    }
}

private enum CertificateValidator {
    static func validate(
        trust: SecTrust,
        expectedHost: String,
        expectedFingerprint: String
    ) -> Result<Void, CertificateValidationError> {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return .failure(.missingTrust)
        }
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard fingerprint == expectedFingerprint else {
            return .failure(.fingerprintMismatch)
        }

        let keys = [
            kSecOIDSubjectAltName,
            kSecOIDExtendedKeyUsage,
            kSecOIDX509V1ValidityNotBefore,
            kSecOIDX509V1ValidityNotAfter
        ] as CFArray
        guard let values = SecCertificateCopyValues(leaf, keys, nil) as? [String: Any],
              let notBefore = certificateDate(kSecOIDX509V1ValidityNotBefore, values: values),
              let notAfter = certificateDate(kSecOIDX509V1ValidityNotAfter, values: values),
              let dnsNames = certificateDNSNames(values: values),
              let extendedKeyUsage = certificateExtendedKeyUsage(values: values) else {
            return .failure(.propertiesUnavailable)
        }
        let now = Date()
        guard now >= notBefore, now <= notAfter else {
            return .failure(.outsideValidityPeriod)
        }
        guard dnsNames.contains(where: { dnsName($0, matches: expectedHost) }) else {
            return .failure(.hostnameMismatch)
        }
        let serverAuthOID = Data([0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01])
        guard extendedKeyUsage.contains(serverAuthOID) else {
            return .failure(.serverAuthMissing)
        }

        let policy = SecPolicyCreateBasicX509()
        guard SecTrustSetPolicies(trust, policy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            return .failure(.invalidX509)
        }
        return .success(())
    }

    private static func certificateDate(_ oid: CFString, values: [String: Any]) -> Date? {
        guard let property = values[oid as String] as? [String: Any],
              let number = property[kSecPropertyKeyValue as String] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: number.doubleValue)
    }

    private static func certificateDNSNames(values: [String: Any]) -> [String]? {
        guard let property = values[kSecOIDSubjectAltName as String] as? [String: Any],
              let entries = property[kSecPropertyKeyValue as String] as? [[String: Any]] else {
            return nil
        }
        return entries.compactMap { $0[kSecPropertyKeyValue as String] as? String }
    }

    private static func certificateExtendedKeyUsage(values: [String: Any]) -> [Data]? {
        guard let property = values[kSecOIDExtendedKeyUsage as String] as? [String: Any] else {
            return nil
        }
        return property[kSecPropertyKeyValue as String] as? [Data]
    }

    private static func dnsName(_ pattern: String, matches host: String) -> Bool {
        let normalizedPattern = pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let normalizedHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard normalizedPattern.hasPrefix("*.") else {
            return normalizedPattern == normalizedHost
        }
        let suffix = String(normalizedPattern.dropFirst(2))
        let hostLabels = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        let suffixLabels = suffix.split(separator: ".", omittingEmptySubsequences: false)
        return hostLabels.count == suffixLabels.count + 1 && normalizedHost.hasSuffix(".\(suffix)")
    }
}

private final class VerificationState: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    func record(_ message: String) {
        lock.lock()
        self.message = message
        lock.unlock()
    }

    func recordedMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }
}

private final class RequestOperation: @unchecked Sendable {
    private let connection: NWConnection
    private let requestData: Data
    private let responseURL: URL
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let verificationState: VerificationState
    private let queue = DispatchQueue(label: "local.token-health.pinned-http")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var isFinished = false
    private var responseData = Data()

    init(
        connection: NWConnection,
        requestData: Data,
        responseURL: URL,
        timeout: TimeInterval,
        maximumResponseBytes: Int,
        verificationState: VerificationState
    ) {
        self.connection = connection
        self.requestData = requestData
        self.responseURL = responseURL
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        self.verificationState = verificationState
    }

    func run() async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()

            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(PinnedHTTPSClient.ClientError.timedOut))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.stateUpdateHandler = nil
            connection.send(content: requestData, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    finish(.failure(connectionError(error)))
                } else {
                    receiveNextChunk()
                }
            })
        case let .failed(error):
            finish(.failure(connectionError(error)))
        case .cancelled:
            finish(.failure(CancellationError()))
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                responseData.append(data)
                guard responseData.count <= maximumResponseBytes else {
                    finish(.failure(PinnedHTTPSClient.ClientError.responseTooLarge))
                    return
                }
                do {
                    if let response = try HTTPResponseParser.completeResponse(from: responseData, url: responseURL) {
                        finish(.success(response))
                        return
                    }
                } catch {
                    finish(.failure(error))
                    return
                }
            }
            if let error {
                finish(.failure(connectionError(error)))
            } else if isComplete {
                do {
                    finish(.success(try HTTPResponseParser.responseAtEndOfStream(from: responseData, url: responseURL)))
                } catch {
                    finish(.failure(error))
                }
            } else {
                receiveNextChunk()
            }
        }
    }

    private func connectionError(_ error: NWError) -> Error {
        if let verificationMessage = verificationState.recordedMessage() {
            return PinnedHTTPSClient.ClientError.certificateVerificationFailed(verificationMessage)
        }
        return PinnedHTTPSClient.ClientError.connectionFailed(error.localizedDescription)
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result)
    }
}

private enum HTTPResponseParser {
    private static let headerDelimiter = Data("\r\n\r\n".utf8)
    private static let lineDelimiter = Data("\r\n".utf8)
    private static let maximumHeaderBytes = 64 * 1_024

    static func completeResponse(from data: Data, url: URL) throws -> (Data, HTTPURLResponse)? {
        guard let headerRange = data.range(of: headerDelimiter) else {
            if data.count > maximumHeaderBytes {
                throw PinnedHTTPSClient.ClientError.invalidResponse("the HTTP headers are too large")
            }
            return nil
        }
        let parsed = try parseHead(data[..<headerRange.lowerBound], url: url)
        let bodyStart = headerRange.upperBound
        let body = data[bodyStart...]

        if parsed.isChunked {
            guard let decoded = try decodeChunkedBody(body) else {
                return nil
            }
            return (decoded, parsed.response)
        }
        if let contentLength = parsed.contentLength {
            guard body.count >= contentLength else {
                return nil
            }
            return (Data(body.prefix(contentLength)), parsed.response)
        }
        return nil
    }

    static func responseAtEndOfStream(from data: Data, url: URL) throws -> (Data, HTTPURLResponse) {
        if let complete = try completeResponse(from: data, url: url) {
            return complete
        }
        guard let headerRange = data.range(of: headerDelimiter) else {
            throw PinnedHTTPSClient.ClientError.invalidResponse("the response ended before its headers were complete")
        }
        let parsed = try parseHead(data[..<headerRange.lowerBound], url: url)
        guard !parsed.isChunked, parsed.contentLength == nil else {
            throw PinnedHTTPSClient.ClientError.invalidResponse("the response body ended before it was complete")
        }
        return (Data(data[headerRange.upperBound...]), parsed.response)
    }

    private static func parseHead(_ data: Data.SubSequence, url: URL) throws -> ParsedHead {
        guard let text = String(data: data, encoding: .isoLatin1) else {
            throw PinnedHTTPSClient.ClientError.invalidResponse("the HTTP headers are not ISO-8859-1")
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw PinnedHTTPSClient.ClientError.invalidResponse("the HTTP status line is missing")
        }
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusParts[1]),
              (100...599).contains(statusCode) else {
            throw PinnedHTTPSClient.ClientError.invalidResponse("the HTTP status line is invalid")
        }

        var headers: [String: String] = [:]
        var normalizedHeaders: [String: [String]] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else {
                throw PinnedHTTPSClient.ClientError.invalidResponse("an HTTP header line is invalid")
            }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                throw PinnedHTTPSClient.ClientError.invalidResponse("an HTTP header name is empty")
            }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
            normalizedHeaders[name.lowercased(), default: []].append(value)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            throw PinnedHTTPSClient.ClientError.invalidResponse("the HTTP response metadata is invalid")
        }

        let transferEncodings = normalizedHeaders["transfer-encoding"] ?? []
        let isChunked = transferEncodings
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains("chunked")
        let contentLength: Int?
        if let values = normalizedHeaders["content-length"] {
            let parsedValues = try values.map { value -> Int in
                guard let length = Int(value), length >= 0 else {
                    throw PinnedHTTPSClient.ClientError.invalidResponse("Content-Length is invalid")
                }
                return length
            }
            guard Set(parsedValues).count == 1 else {
                throw PinnedHTTPSClient.ClientError.invalidResponse("Content-Length values disagree")
            }
            contentLength = parsedValues.first
        } else {
            contentLength = nil
        }
        return ParsedHead(response: response, contentLength: contentLength, isChunked: isChunked)
    }

    private static func decodeChunkedBody(_ data: Data.SubSequence) throws -> Data? {
        var cursor = data.startIndex
        var decoded = Data()
        while true {
            guard let lineRange = data[cursor...].range(of: lineDelimiter) else {
                return nil
            }
            guard let line = String(data: data[cursor..<lineRange.lowerBound], encoding: .ascii) else {
                throw PinnedHTTPSClient.ClientError.invalidResponse("a chunk size is invalid")
            }
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard let chunkSize = Int(sizeText, radix: 16), chunkSize >= 0 else {
                throw PinnedHTTPSClient.ClientError.invalidResponse("a chunk size is invalid")
            }
            cursor = lineRange.upperBound
            if chunkSize == 0 {
                while true {
                    guard let trailerRange = data[cursor...].range(of: lineDelimiter) else {
                        return nil
                    }
                    if trailerRange.lowerBound == cursor {
                        return decoded
                    }
                    cursor = trailerRange.upperBound
                }
            }
            guard data.distance(from: cursor, to: data.endIndex) >= chunkSize + lineDelimiter.count else {
                return nil
            }
            let chunkEnd = data.index(cursor, offsetBy: chunkSize)
            decoded.append(contentsOf: data[cursor..<chunkEnd])
            let delimiterEnd = data.index(chunkEnd, offsetBy: lineDelimiter.count)
            guard data[chunkEnd..<delimiterEnd].elementsEqual(lineDelimiter) else {
                throw PinnedHTTPSClient.ClientError.invalidResponse("a chunk terminator is invalid")
            }
            cursor = delimiterEnd
        }
    }

    private struct ParsedHead {
        let response: HTTPURLResponse
        let contentLength: Int?
        let isChunked: Bool
    }
}
