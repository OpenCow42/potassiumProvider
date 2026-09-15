import Foundation

/// Only known request-field classes leave the response parser. Messages, field
/// values, unrecognized keys, and indices never enter a diagnostic bundle.
public enum ProviderDiagnosticValidationField: String, Codable, Sendable {
    case includedResources, actions, files, fromDate, modificationDate

    public static func classify(_ error: any Error) -> [Self]? {
        guard let rejection = KDriveRemoteErrorClassifier.apiRejection(from: error), [400, 422].contains(rejection.statusCode),
              let data = rejection.responseBody.data(using: .utf8), data.count <= 64 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var fields = Set<Self>()
        func field(_ key: String) -> Self? {
            switch key.split(separator: ".").first {
            case "with": return .includedResources
            case "actions": return .actions
            case "files": return .files
            case "from_date": return .fromDate
            case "last_modified_at": return .modificationDate
            default: return nil
            }
        }
        func visit(_ value: Any, depth: Int) {
            guard depth < 6 else { return }
            if let array = value as? [Any] {
                for child in array.prefix(200) { visit(child, depth: depth + 1) }
                return
            }
            guard let object = value as? [String: Any] else { return }
            for (key, child) in object {
                if let known = field(key) { fields.insert(known) }
                if ["field", "parameter"].contains(key), let name = child as? String, let known = field(name) {
                    fields.insert(known)
                }
                visit(child, depth: depth + 1)
            }
        }
        visit(root, depth: 0)
        return fields.isEmpty ? nil : fields.sorted { $0.rawValue < $1.rawValue }
    }
}
