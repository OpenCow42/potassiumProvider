import Foundation
import Security

public protocol VaultKeyStoring: Sendable {
    func loadRootKey(vaultID: VaultIdentifier) async throws -> VaultKeyMaterial?
    func saveRootKey(_ key: VaultKeyMaterial, vaultID: VaultIdentifier) async throws
    func deleteRootKey(vaultID: VaultIdentifier) async throws
    func loadTrustedState(vaultID: VaultIdentifier) async throws -> VaultTrustedState?
    func saveTrustedState(_ state: VaultTrustedState) async throws
    func deleteTrustedState(vaultID: VaultIdentifier) async throws
}

public protocol VaultDeviceIdentityStoring: Sendable {
    func loadOrCreateDeviceID(vaultID: VaultIdentifier) async throws -> UUID
}

public actor KeychainVaultKeyStore: VaultKeyStoring, VaultDeviceIdentityStoring {
    private let service: String
    private let accessGroup: String?

    public init(
        service: String = ProviderConstants.vaultKeychainService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func loadRootKey(vaultID: VaultIdentifier) throws -> VaultKeyMaterial? {
        guard let data = try loadData(account: rootKeyAccount(vaultID)) else { return nil }
        guard let key = VaultKeyMaterial(data: data) else {
            throw VaultCryptoError.invalidKeyLength
        }
        return key
    }

    public func saveRootKey(_ key: VaultKeyMaterial, vaultID: VaultIdentifier) throws {
        try saveData(key.data, account: rootKeyAccount(vaultID))
    }

    public func deleteRootKey(vaultID: VaultIdentifier) throws {
        try deleteData(account: rootKeyAccount(vaultID))
    }

    public func loadTrustedState(vaultID: VaultIdentifier) throws -> VaultTrustedState? {
        guard let data = try loadData(account: trustedStateAccount(vaultID)) else { return nil }
        return try VaultCoding.decoder.decode(VaultTrustedState.self, from: data)
    }

    public func saveTrustedState(_ state: VaultTrustedState) throws {
        try saveData(
            try VaultCoding.encoder.encode(state),
            account: trustedStateAccount(state.vaultID)
        )
    }

    public func deleteTrustedState(vaultID: VaultIdentifier) throws {
        try deleteData(account: trustedStateAccount(vaultID))
    }

    public func loadOrCreateDeviceID(vaultID: VaultIdentifier) throws -> UUID {
        let account = deviceIDAccount(vaultID)
        if let data = try loadData(account: account),
           data.count == MemoryLayout<uuid_t>.size {
            return UUID(bytes: data)
        }
        let identifier = UUID()
        try saveData(identifier.data, account: account)
        return identifier
    }

    private func loadData(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw VaultKeyStoreError.unhandledStatus(status)
        }
        return data
    }

    private func saveData(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let attributes = saveAttributes(data: data)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw VaultKeyStoreError.unhandledStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultKeyStoreError.unhandledStatus(status)
        }
    }

    func saveAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }

    private func deleteData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw VaultKeyStoreError.unhandledStatus(status)
        }
    }

    func baseQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func rootKeyAccount(_ vaultID: VaultIdentifier) -> String {
        "vaultRootKey:\(vaultID.rawValue.uuidString.lowercased())"
    }

    private func trustedStateAccount(_ vaultID: VaultIdentifier) -> String {
        "vaultTrustedState:\(vaultID.rawValue.uuidString.lowercased())"
    }

    private func deviceIDAccount(_ vaultID: VaultIdentifier) -> String {
        "vaultDeviceID:\(vaultID.rawValue.uuidString.lowercased())"
    }
}

public actor InMemoryVaultKeyStore: VaultKeyStoring {
    private var keys: [VaultIdentifier: VaultKeyMaterial] = [:]
    private var trustedStates: [VaultIdentifier: VaultTrustedState] = [:]

    public init() {}

    public func loadRootKey(vaultID: VaultIdentifier) -> VaultKeyMaterial? {
        keys[vaultID]
    }

    public func saveRootKey(_ key: VaultKeyMaterial, vaultID: VaultIdentifier) {
        keys[vaultID] = key
    }

    public func deleteRootKey(vaultID: VaultIdentifier) {
        keys[vaultID] = nil
    }

    public func loadTrustedState(vaultID: VaultIdentifier) -> VaultTrustedState? {
        trustedStates[vaultID]
    }

    public func saveTrustedState(_ state: VaultTrustedState) {
        trustedStates[state.vaultID] = state
    }

    public func deleteTrustedState(vaultID: VaultIdentifier) {
        trustedStates[vaultID] = nil
    }
}

public enum VaultKeyStoreError: Error, Equatable, LocalizedError, Sendable {
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            return "Vault keychain operation failed with status \(status)."
        }
    }
}
