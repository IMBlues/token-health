import Foundation

struct PlanNameExtractor {
    func find(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return find(in: object)
    }

    func find(in value: Any) -> String? {
        findValue(in: value, keyPath: [])
    }

    private func findValue(in value: Any, keyPath: [String]) -> String? {
        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let nextPath = keyPath + [key]
                if let string = child as? String,
                   isPlanKey(nextPath),
                   isUsefulPlanName(string) {
                    return clean(string)
                }

                if let nested = findValue(in: child, keyPath: nextPath) {
                    return nested
                }
            }
        }

        if let array = value as? [Any] {
            for child in array {
                if let nested = findValue(in: child, keyPath: keyPath) {
                    return nested
                }
            }
        }

        if let string = value as? String,
           let parsed = parseEmbeddedJSON(string),
           let nested = findValue(in: parsed, keyPath: keyPath) {
            return nested
        }

        return nil
    }

    private func isPlanKey(_ keyPath: [String]) -> Bool {
        let key = keyPath.joined(separator: "_").lowercased()
        let planWords = ["plan", "package", "subscription", "product", "sku", "tier", "套餐"]
        let nameWords = ["name", "title", "display", "label", "名称"]
        return planWords.contains(where: key.contains)
            && nameWords.contains(where: key.contains)
    }

    private func isUsefulPlanName(_ value: String) -> Bool {
        let cleaned = clean(value)
        guard cleaned.count >= 2, cleaned.count <= 80 else {
            return false
        }
        let lower = cleaned.lowercased()
        if lower.contains("http")
            || lower.contains("token")
            || lower.contains("bearer")
            || lower.contains("{")
            || lower.contains("[") {
            return false
        }
        return true
    }

    private func clean(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseEmbeddedJSON(_ string: String) -> Any? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[" else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
