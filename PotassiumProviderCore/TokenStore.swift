import Foundation
import Security

public protocol OAuthTokenStoring: Sendable {
    func loadToken(accountIdentifier: String) async throws -> KDriveOAuthToken?
    func saveToken(_ token: KDriveOAuthToken, accountIdentifier: String) async throws
    func deleteToken(accountIdentifier: String) async throws
    func loadLegacyToken() async throws -> KDriveOAuthToken?
    func deleteLegacyToken() async throws
}

public extension OAuthTokenStoring {
    func loadToken() async throws -> KDriveOAuthToken? {
        try await loadToken(accountIdentifier: ProviderConstants.legacyAccountIdentifier)
    }

    func saveToken(_ token: KDriveOAuthToken) async throws {
        try await saveToken(token, accountIdentifier: ProviderConstants.legacyAccountIdentifier)
    }

    func deleteToken() async throws {
        try await deleteToken(accountIdentifier: ProviderConstants.legacyAccountIdentifier)
    }

    @discardableResult
    func migrateLegacyToken(to accountIdentifier: String) async throws -> Bool {
        guard let legacyToken = try await loadLegacyToken() else {
            return false
        }

        if try await loadToken(accountIdentifier: accountIdentifier) == nil {
            try await saveToken(legacyToken, accountIdentifier: accountIdentifier)
        }
        try await deleteLegacyToken()
        return true
    }
}

public actor KeychainOAuthTokenStore: OAuthTokenStoring {
    private let service: String
    private let legacyAccount: String
    private let accessGroup: String?

    public init(
        service: String = ProviderConstants.keychainService,
        account: String = ProviderConstants.keychainAccount,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.legacyAccount = account
        self.accessGroup = accessGroup
    }

    public func loadToken(accountIdentifier: String) async throws -> KDriveOAuthToken? {
        try loadToken(keychainAccount: Self.keychainAccount(for: accountIdentifier))
    }

    public func saveToken(_ token: KDriveOAuthToken, accountIdentifier: String) async throws {
        try saveToken(token, keychainAccount: Self.keychainAccount(for: accountIdentifier))
    }

    public func deleteToken(accountIdentifier: String) async throws {
        try deleteToken(keychainAccount: Self.keychainAccount(for: accountIdentifier))
    }

    public func loadLegacyToken() async throws -> KDriveOAuthToken? {
        try loadToken(keychainAccount: legacyAccount)
    }

    public func deleteLegacyToken() async throws {
        try deleteToken(keychainAccount: legacyAccount)
    }

    public static func keychainAccount(for accountIdentifier: String) -> String {
        "\(ProviderConstants.keychainAccount):\(accountIdentifier)"
    }

    private func loadToken(keychainAccount: String) throws -> KDriveOAuthToken? {
        var query = baseQuery(account: keychainAccount)
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

    private func saveToken(_ token: KDriveOAuthToken, keychainAccount: String) throws {
        let data = try makeEncoder().encode(token)
        let query = baseQuery(account: keychainAccount)
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

    private func deleteToken(keychainAccount: String) throws {
        let status = SecItemDelete(baseQuery(account: keychainAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainTokenStoreError.unhandledStatus(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
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
    private var tokens: [String: KDriveOAuthToken]
    private var legacyToken: KDriveOAuthToken?

    public init(token: KDriveOAuthToken? = nil) {
        if let token {
            self.tokens = [ProviderConstants.legacyAccountIdentifier: token]
            self.legacyToken = token
        } else {
            self.tokens = [:]
            self.legacyToken = nil
        }
    }

    public func loadToken(accountIdentifier: String) -> KDriveOAuthToken? {
        tokens[accountIdentifier]
    }

    public func saveToken(_ token: KDriveOAuthToken, accountIdentifier: String) {
        tokens[accountIdentifier] = token
    }

    public func deleteToken(accountIdentifier: String) {
        tokens[accountIdentifier] = nil
    }

    public func loadLegacyToken() -> KDriveOAuthToken? {
        legacyToken
    }

    public func deleteLegacyToken() {
        legacyToken = nil
    }

    public func loadToken() -> KDriveOAuthToken? {
        tokens[ProviderConstants.legacyAccountIdentifier]
    }

    public func saveToken(_ token: KDriveOAuthToken) {
        tokens[ProviderConstants.legacyAccountIdentifier] = token
    }

    public func deleteToken() {
        tokens[ProviderConstants.legacyAccountIdentifier] = nil
    }

    public func accountIdentifiersWithTokens() -> [String] {
        tokens.keys.sorted()
    }
}
