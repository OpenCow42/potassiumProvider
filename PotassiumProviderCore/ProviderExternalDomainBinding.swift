import Foundation

public struct ProviderExternalDomainBinding: Equatable, Sendable {
    public let configurationIdentifier: String

    public init(configurationIdentifier: String) {
        self.configurationIdentifier = configurationIdentifier
    }
}

public enum ProviderExternalDomainUserInfoCodec {
    public static let currentSchemaVersion = 1
    public static let schemaVersionKey = "net.weavee.potassiumProvider.externalBindingSchemaVersion"
    public static let configurationIdentifierKey = "net.weavee.potassiumProvider.configurationIdentifier"

    public static func userInfo(configurationIdentifier: String) -> [String: Any] {
        [
            schemaVersionKey: NSNumber(value: currentSchemaVersion),
            configurationIdentifierKey: configurationIdentifier,
        ]
    }

    public static func containsBinding(in userInfo: [AnyHashable: Any]?) -> Bool {
        guard let userInfo else { return false }
        return userInfo[schemaVersionKey] != nil || userInfo[configurationIdentifierKey] != nil
    }

    public static func decode(_ userInfo: [AnyHashable: Any]?) throws -> ProviderExternalDomainBinding {
        guard let userInfo,
              let schemaVersion = userInfo[schemaVersionKey] as? NSNumber,
              schemaVersion.intValue == currentSchemaVersion
        else {
            throw ProviderExternalDomainBindingDecodingError.unsupportedSchema
        }

        guard let rawConfigurationIdentifier = userInfo[configurationIdentifierKey] as? String else {
            throw ProviderExternalDomainBindingDecodingError.missingConfigurationIdentifier
        }
        let configurationIdentifier = rawConfigurationIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configurationIdentifier.isEmpty == false else {
            throw ProviderExternalDomainBindingDecodingError.missingConfigurationIdentifier
        }

        return ProviderExternalDomainBinding(configurationIdentifier: configurationIdentifier)
    }
}

public enum ProviderExternalDomainBindingDecodingError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchema
    case missingConfigurationIdentifier

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema:
            return "The external File Provider domain uses an unsupported binding format."
        case .missingConfigurationIdentifier:
            return "The external File Provider domain has no configuration binding."
        }
    }
}
