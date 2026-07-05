import Foundation
import Security

public protocol OAuthTokenStoring: Sendable {
    func loadToken() async throws -> KDriveOAuthToken?
    func saveToken(_ token: KDriveOAuthToken) async throws
    func deleteToken() async throws
}

public final class KeychainOAuthTokenStore: OAuthTokenStoring, @unchecked Sendable {
    private let service: String
    private let account: String
    private let accessGroup: String?

    public init(
        service: String = ProviderConstants.keychainService,
        account: String = ProviderConstants.keychainAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    public func loadToken() async throws -> KDriveOAuthToken? {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
        return try makeDecoder().decode(KDriveOAuthToken.self, from: data)
    }

    public func saveToken(_ token: KDriveOAuthToken) async throws {
        let data = try makeEncoder().encode(token)
        let query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainTokenStoreError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainTokenStoreError.unhandledStatus(addStatus)
        }
    }

    public func deleteToken() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum KeychainTokenStoreError: Error, Equatable, LocalizedError, Sendable {
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Keychain token operation failed with status \(status)."
        }
    }
}

public actor InMemoryOAuthTokenStore: OAuthTokenStoring {
    private var token: KDriveOAuthToken?

    public init(token: KDriveOAuthToken? = nil) {
        self.token = token
    }

    public func loadToken() -> KDriveOAuthToken? {
        token
    }

    public func saveToken(_ token: KDriveOAuthToken) {
        self.token = token
    }

    public func deleteToken() {
        token = nil
    }
}
