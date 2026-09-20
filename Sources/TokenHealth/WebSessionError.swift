import Foundation

enum WebSessionError: LocalizedError {
    case unsupportedProvider
    case cancelled(providerTitle: String)
    case sessionExpired(providerTitle: String)
    case loadTimeout(providerTitle: String, seconds: Int)
    case invalidResponse(providerTitle: String)
    case requestFailed(providerTitle: String, message: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider:
            "This provider does not support web login"
        case let .cancelled(providerTitle):
            "\(providerTitle) login cancelled"
        case let .sessionExpired(providerTitle):
            "\(providerTitle) session expired. Log in again for this account."
        case let .loadTimeout(providerTitle, seconds):
            "\(providerTitle) page did not load within \(seconds) seconds."
        case let .invalidResponse(providerTitle):
            "\(providerTitle) usage response was invalid"
        case let .requestFailed(_, message):
            message
        }
    }
}
