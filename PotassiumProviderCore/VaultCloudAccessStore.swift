import Foundation
import Security

private struct VaultCloudAccessCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct StrictVaultRemoteLayout: Decodable {
    let value: VaultBootstrap.RemoteLayout

    private enum CodingKeys: String, CodingKey {
        case contentContainerID
        case journalContainerID
        case checkpointContainerID
        case checkpointToken
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(
            keyedBy: VaultCloudAccessCodingKey.self
        )
        let expectedKeys = Set([
            "contentContainerID",
            "journalContainerID",
            "checkpointContainerID",
            "checkpointToken",
        ])
        guard Set(rawContainer.allKeys.map(\.stringValue)) == expectedKeys else {
            throw VaultCloudAccessStoreError.malformedRecord
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let contentContainerID = try container.decode(
            Int.self,
            forKey: .contentContainerID
        )
        let journalContainerID = try container.decode(
            Int.self,
            forKey: .journalContainerID
        )
        let checkpointContainerID = try container.decode(
            Int.self,
            forKey: .checkpointContainerID
        )
        let checkpointToken = try container.decode(
            String.self,
            forKey: .checkpointToken
        )
        guard contentContainerID > 0,
              journalContainerID > 0,
              checkpointContainerID > 0,
              let token = Data(base64URLEncoded: checkpointToken),
              token.count == 20 else {
            throw VaultCloudAccessStoreError.malformedRecord
        }
        value = VaultBootstrap.RemoteLayout(
            contentContainerID: contentContainerID,
            journalContainerID: journalContainerID,
            checkpointContainerID: checkpointContainerID,
            checkpointToken: checkpointToken
        )
    }
}

/// A convenience copy of the information required to open a vault on another
/// trusted Apple device. This record never contains the recovery secret,
/// rollback frontier, or device identity.
public struct VaultCloudAccessRecord: Codable, Equatable, Sendable {
    public static let currentRecordVersion: UInt16 = 1

    public let recordVersion: UInt16
    public let vaultID: VaultIdentifier
    public let driveID: Int
    public let vaultRootFileID: Int
    public let vaultHeaderFileID: Int
    public let formatVersion: UInt16
    public let keyEpoch: UInt32
    public let remoteLayout: VaultBootstrap.RemoteLayout
    public let rootKey: VaultKeyMaterial
    public let createdAt: Date

    public init(
        vaultID: VaultIdentifier,
        driveID: Int,
        vaultRootFileID: Int,
        vaultHeaderFileID: Int,
        formatVersion: UInt16,
        keyEpoch: UInt32,
        remoteLayout: VaultBootstrap.RemoteLayout,
        rootKey: VaultKeyMaterial,
        createdAt: Date = Date()
    ) {
        recordVersion = Self.currentRecordVersion
        self.vaultID = vaultID
        self.driveID = driveID
        self.vaultRootFileID = vaultRootFileID
        self.vaultHeaderFileID = vaultHeaderFileID
        self.formatVersion = formatVersion
        self.keyEpoch = keyEpoch
        self.remoteLayout = remoteLayout
        self.rootKey = rootKey
        self.createdAt = createdAt
    }

    public init(
        configuration: ProviderVaultConfiguration,
        driveID: Int,
        rootKey: VaultKeyMaterial,
        createdAt: Date = Date()
    ) throws {
        guard let remoteLayout = configuration.remoteLayout else {
            throw VaultCloudAccessStoreError.malformedRecord
        }
        self.init(
            vaultID: configuration.vaultIdentifier,
            driveID: driveID,
            vaultRootFileID: configuration.vaultRootFileID,
            vaultHeaderFileID: configuration.vaultHeaderFileID,
            formatVersion: configuration.formatVersion,
            keyEpoch: configuration.keyEpoch,
            remoteLayout: remoteLayout,
            rootKey: rootKey,
            createdAt: createdAt
        )
    }

    public var vaultConfiguration: ProviderVaultConfiguration {
        ProviderVaultConfiguration(
            vaultIdentifier: vaultID,
            vaultRootFileID: vaultRootFileID,
            vaultHeaderFileID: vaultHeaderFileID,
            formatVersion: formatVersion,
            keyEpoch: keyEpoch,
            remoteLayout: remoteLayout
        )
    }

    private enum CodingKeys: String, CodingKey {
        case recordVersion
        case vaultID
        case driveID
        case vaultRootFileID
        case vaultHeaderFileID
        case formatVersion
        case keyEpoch
        case remoteLayout
        case rootKey
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(
            keyedBy: VaultCloudAccessCodingKey.self
        )
        let expectedKeys = Set([
            "recordVersion",
            "vaultID",
            "driveID",
            "vaultRootFileID",
            "vaultHeaderFileID",
            "formatVersion",
            "keyEpoch",
            "remoteLayout",
            "rootKey",
            "createdAt",
        ])
        guard Set(rawContainer.allKeys.map(\.stringValue)) == expectedKeys else {
            throw VaultCloudAccessStoreError.malformedRecord
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordVersion = try container.decode(UInt16.self, forKey: .recordVersion)
        guard recordVersion == Self.currentRecordVersion else {
            throw VaultCloudAccessStoreError.unsupportedRecordVersion(recordVersion)
        }
        vaultID = try container.decode(VaultIdentifier.self, forKey: .vaultID)
        driveID = try container.decode(Int.self, forKey: .driveID)
        vaultRootFileID = try container.decode(Int.self, forKey: .vaultRootFileID)
        vaultHeaderFileID = try container.decode(Int.self, forKey: .vaultHeaderFileID)
        formatVersion = try container.decode(UInt16.self, forKey: .formatVersion)
        keyEpoch = try container.decode(UInt32.self, forKey: .keyEpoch)
        remoteLayout = try container.decode(
            StrictVaultRemoteLayout.self,
            forKey: .remoteLayout
        ).value
        let rootKeyData = try container.decode(Data.self, forKey: .rootKey)
        guard let rootKey = VaultKeyMaterial(data: rootKeyData) else {
            throw VaultCloudAccessStoreError.malformedRecord
        }
        self.rootKey = rootKey
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        guard driveID > 0,
              vaultRootFileID > 0,
              vaultHeaderFileID > 0,
              formatVersion == VaultFormat.currentVersion,
              keyEpoch > 0 else {
            throw VaultCloudAccessStoreError.malformedRecord
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(recordVersion, forKey: .recordVersion)
        try container.encode(vaultID, forKey: .vaultID)
        try container.encode(driveID, forKey: .driveID)
        try container.encode(vaultRootFileID, forKey: .vaultRootFileID)
        try container.encode(vaultHeaderFileID, forKey: .vaultHeaderFileID)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(keyEpoch, forKey: .keyEpoch)
        try container.encode(remoteLayout, forKey: .remoteLayout)
        try container.encode(rootKey.data, forKey: .rootKey)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct VaultCloudAccessCandidate: Identifiable, Equatable, Sendable {
    public var id: VaultIdentifier { vaultID }

    public let vaultID: VaultIdentifier
    public let driveID: Int
    public let keyEpoch: UInt32
    public let createdAt: Date

    public init(record: VaultCloudAccessRecord) {
        vaultID = record.vaultID
        driveID = record.driveID
        keyEpoch = record.keyEpoch
        createdAt = record.createdAt
    }
}

public enum VaultCloudAccessStatus: Equatable, Sendable {
    case disabled
    case available
    case unavailable
    case staleEpoch
    case conflict
}

public enum VaultLocalKeyStatus: Equatable, Sendable {
    case available
    case locked
    case missing
    case invalid
}

public enum VaultSetupStep: String, Codable, Equatable, Sendable {
    case unsupportedRiskWarning
    case overview
    case keyAccess
    case recoveryKit
    case registering
    case desktopDocuments
    case complete
}

public struct VaultSetupOutcome: Equatable, Sendable {
    public var configuration: ProviderDomainConfiguration?
    public var cloudAccessStatus: VaultCloudAccessStatus
    public var recoveryKitVerified: Bool
    public var desktopDocumentsDeferred: Bool
    public var desktopDocumentsEnabled: Bool

    public init(
        configuration: ProviderDomainConfiguration? = nil,
        cloudAccessStatus: VaultCloudAccessStatus = .disabled,
        recoveryKitVerified: Bool = false,
        desktopDocumentsDeferred: Bool = false,
        desktopDocumentsEnabled: Bool = false
    ) {
        self.configuration = configuration
        self.cloudAccessStatus = cloudAccessStatus
        self.recoveryKitVerified = recoveryKitVerified
        self.desktopDocumentsDeferred = desktopDocumentsDeferred
        self.desktopDocumentsEnabled = desktopDocumentsEnabled
    }
}

public struct VaultUXPreferences: Codable, Equatable, Sendable {
    public static let currentOnboardingVersion = 1

    public var onboardingVersion: Int
    public var desktopDocumentsDeferred: Bool

    public init(
        onboardingVersion: Int = Self.currentOnboardingVersion,
        desktopDocumentsDeferred: Bool = false
    ) {
        self.onboardingVersion = onboardingVersion
        self.desktopDocumentsDeferred = desktopDocumentsDeferred
    }
}

public protocol VaultCloudAccessStoring: Sendable {
    func records() async throws -> [VaultCloudAccessRecord]
    func record(vaultID: VaultIdentifier) async throws -> VaultCloudAccessRecord?
    func save(_ record: VaultCloudAccessRecord) async throws
    func delete(vaultID: VaultIdentifier) async throws
}

public actor KeychainVaultCloudAccessStore: VaultCloudAccessStoring {
    public let service: String
    public let accessGroup: String?

    public init(
        service: String = ProviderConstants.vaultCloudAccessKeychainService,
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func records() throws -> [VaultCloudAccessRecord] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try Self.validate(status)

        let payloads: [Data]
        if let values = result as? [Data] {
            payloads = values
        } else if let value = result as? Data {
            payloads = [value]
        } else {
            throw VaultCloudAccessStoreError.malformedRecord
        }
        return try payloads.map(Self.decode)
    }

    public func record(vaultID: VaultIdentifier) throws -> VaultCloudAccessRecord? {
        var query = baseQuery(account: account(vaultID))
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try Self.validate(status)
        guard let data = result as? Data else {
            throw VaultCloudAccessStoreError.malformedRecord
        }
        let record = try Self.decode(data)
        guard record.vaultID == vaultID else {
            throw VaultCloudAccessStoreError.conflictingRecord
        }
        return record
    }

    public func save(_ record: VaultCloudAccessRecord) throws {
        let data = try VaultCoding.encoder.encode(record)
        let query = baseQuery(account: account(record.vaultID))
        let attributes = saveAttributes(data: data)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            try Self.validate(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        try Self.validate(status)
    }

    func saveAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
    }

    public func delete(vaultID: VaultIdentifier) throws {
        let status = SecItemDelete(
            baseQuery(account: account(vaultID)) as CFDictionary
        )
        guard status != errSecItemNotFound else { return }
        try Self.validate(status)
    }

    /// Exposed internally so tests can lock the synchronization and data
    /// protection attributes without exercising a user's actual iCloud Keychain.
    func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func account(_ vaultID: VaultIdentifier) -> String {
        "vaultCloudAccess:\(vaultID.rawValue.uuidString.lowercased())"
    }

    private static func decode(_ data: Data) throws -> VaultCloudAccessRecord {
        do {
            return try VaultCoding.decoder.decode(
                VaultCloudAccessRecord.self,
                from: data
            )
        } catch let error as VaultCloudAccessStoreError {
            throw error
        } catch {
            throw VaultCloudAccessStoreError.malformedRecord
        }
    }

    private static func validate(_ status: OSStatus) throws {
        guard status != errSecInteractionNotAllowed else {
            throw VaultCloudAccessStoreError.interactionNotAllowed
        }
        guard status == errSecSuccess else {
            throw VaultCloudAccessStoreError.unhandledStatus(status)
        }
    }
}

public actor InMemoryVaultCloudAccessStore: VaultCloudAccessStoring {
    private var values: [VaultIdentifier: VaultCloudAccessRecord] = [:]

    public init(records: [VaultCloudAccessRecord] = []) {
        values = Dictionary(uniqueKeysWithValues: records.map { ($0.vaultID, $0) })
    }

    public func records() -> [VaultCloudAccessRecord] {
        values.values.sorted {
            $0.vaultID.rawValue.uuidString < $1.vaultID.rawValue.uuidString
        }
    }

    public func record(vaultID: VaultIdentifier) -> VaultCloudAccessRecord? {
        values[vaultID]
    }

    public func save(_ record: VaultCloudAccessRecord) {
        values[record.vaultID] = record
    }

    public func delete(vaultID: VaultIdentifier) {
        values[vaultID] = nil
    }
}

public enum VaultCloudAccessStoreError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedRecordVersion(UInt16)
    case malformedRecord
    case conflictingRecord
    case interactionNotAllowed
    case unhandledStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .unsupportedRecordVersion(let version):
            return "iCloud Keychain vault record version \(version) is not supported."
        case .malformedRecord:
            return "The iCloud Keychain vault record is malformed."
        case .conflictingRecord:
            return "iCloud Keychain contains a conflicting vault record."
        case .interactionNotAllowed:
            return "Unlock this device before accessing the iCloud Keychain vault record."
        case .unhandledStatus(let status):
            return "iCloud Keychain access failed with status \(status)."
        }
    }
}
