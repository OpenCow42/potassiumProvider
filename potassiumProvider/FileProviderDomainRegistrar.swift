import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

@MainActor
protocol ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws
    func prepareDomain(
        configurationIdentifier: String,
        domainIdentifier: String,
        displayName: String,
        target: ProviderDomainPreparationTarget
    ) throws -> ProviderPreparedDomain
    func addPreparedDomain(_ preparedDomain: ProviderPreparedDomain) async throws
    func registeredDomainStates() async throws -> [ProviderRegisteredDomainState]
    func waitForStabilization(for configuration: ProviderDomainConfiguration) async throws
    func removeDomainPreservingDirtyUserData(for configuration: ProviderDomainConfiguration) async throws -> URL?
    func reconnectDomain(for configuration: ProviderDomainConfiguration) async throws
    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState]
    func claimKnownFolders(for configuration: ProviderDomainConfiguration, parentFileID: Int) async throws
    func releaseKnownFolders(for configuration: ProviderDomainConfiguration) async throws
}

enum ProviderDomainPreparationTarget: Equatable, Sendable {
    case onThisMac
    case externalVolume(URL)
}

@MainActor
struct ProviderPreparedDomain {
    let configurationIdentifier: String
    let domainIdentifier: String
    let volumeUUID: UUID?

    let fileProviderDomain: NSFileProviderDomain
}

struct ProviderRegisteredDomainState: Equatable, Sendable {
    let configurationIdentifier: String?
    let domainIdentifier: String
    let displayName: String
    let volumeUUID: UUID?
    let isDisconnected: Bool
    let isUserEnabled: Bool
    let knownFolderSyncState: ProviderKnownFolderSyncState
}

enum ProviderKnownFolderSyncState: Equatable, Sendable {
    case unavailable
    case inactive
    case partial
    case active
}

extension ProviderDomainRegistering {
    func prepareDomain(
        configurationIdentifier _: String,
        domainIdentifier _: String,
        displayName _: String,
        target _: ProviderDomainPreparationTarget
    ) throws -> ProviderPreparedDomain {
        throw ProviderDomainRegistrationError.preparedDomainUnsupported
    }

    func addPreparedDomain(_: ProviderPreparedDomain) async throws {
        throw ProviderDomainRegistrationError.preparedDomainUnsupported
    }

    func registeredDomainStates() async throws -> [ProviderRegisteredDomainState] {
        []
    }

    func waitForStabilization(for _: ProviderDomainConfiguration) async throws {
        throw ProviderDomainRegistrationError.stabilizationUnsupported
    }

    func removeDomainPreservingDirtyUserData(for configuration: ProviderDomainConfiguration) async throws -> URL? {
        try await removeDomain(for: configuration)
        return nil
    }

    func reconnectDomain(for _: ProviderDomainConfiguration) async throws {
        throw ProviderDomainRegistrationError.reconnectionUnsupported
    }

    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState] {
        [:]
    }

    func claimKnownFolders(for configuration: ProviderDomainConfiguration, parentFileID: Int) async throws {
        throw ProviderKnownFolderRegistrationError.unsupportedPlatform
    }

    func releaseKnownFolders(for configuration: ProviderDomainConfiguration) async throws {
        throw ProviderKnownFolderRegistrationError.unsupportedPlatform
    }
}

@MainActor
struct FileProviderDomainRegistrar: ProviderDomainRegistering {
    nonisolated private static let logger = ProviderLog.domain

    private let system: FileProviderDomainSystemClient

    init(system: FileProviderDomainSystemClient? = nil) {
        self.system = system ?? .live
    }

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        let domain = try await domainForExistingOperation(configuration)

        Self.logger.info("addDomain(\(configuration.domainIdentifier, privacy: .public)) displayName(\(configuration.displayName, privacy: .private)) driveID(\(configuration.driveID, privacy: .public))")
        do {
            try await system.addDomain(domain)
            Self.logger.info("added domain(\(configuration.domainIdentifier, privacy: .public)) to File Provider")
        } catch {
            Self.logger.error("failed to addDomain(\(configuration.domainIdentifier, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {
        let domain = try await domainForExistingOperation(configuration)

        Self.logger.info("removeDomain(\(configuration.domainIdentifier, privacy: .public)) displayName(\(configuration.displayName, privacy: .private))")
        do {
            try await system.removeDomain(domain)
            Self.logger.info("removed domain(\(configuration.domainIdentifier, privacy: .public)) from File Provider")
        } catch {
            Self.logger.error("failed to removeDomain(\(configuration.domainIdentifier, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func prepareDomain(
        configurationIdentifier: String,
        domainIdentifier: String,
        displayName: String,
        target: ProviderDomainPreparationTarget
    ) throws -> ProviderPreparedDomain {
        let domain: NSFileProviderDomain
        let volumeUUID: UUID?
        switch target {
        case .onThisMac:
            domain = NSFileProviderDomain(
                identifier: NSFileProviderDomainIdentifier(rawValue: domainIdentifier),
                displayName: displayName
            )
            volumeUUID = nil
        case .externalVolume(let volumeURL):
            #if os(macOS)
            domain = NSFileProviderDomain(
                displayName: displayName,
                userInfo: ProviderExternalDomainUserInfoCodec.userInfo(
                    configurationIdentifier: configurationIdentifier
                ),
                volumeURL: volumeURL
            )
            volumeUUID = domain.volumeUUID
            #else
            throw ProviderDomainRegistrationError.externalVolumesUnsupported
            #endif
        }

        #if os(macOS)
        domain.supportedKnownFolders = [.desktop, .documents]
        #endif

        return ProviderPreparedDomain(
            configurationIdentifier: configurationIdentifier,
            domainIdentifier: domain.identifier.rawValue,
            volumeUUID: volumeUUID,
            fileProviderDomain: domain
        )
    }

    func addPreparedDomain(_ preparedDomain: ProviderPreparedDomain) async throws {
        Self.logger.info("add prepared domain(\(preparedDomain.domainIdentifier, privacy: .public)) configuration(\(preparedDomain.configurationIdentifier, privacy: .public))")
        try await system.addDomain(preparedDomain.fileProviderDomain)
    }

    func registeredDomainStates() async throws -> [ProviderRegisteredDomainState] {
        #if os(macOS)
        try await registeredDomains().map { domain in
            ProviderRegisteredDomainState(
                configurationIdentifier: try? ProviderExternalDomainUserInfoCodec.decode(
                    domain.userInfo
                ).configurationIdentifier,
                domainIdentifier: domain.identifier.rawValue,
                displayName: domain.displayName,
                volumeUUID: domain.volumeUUID,
                isDisconnected: domain.isDisconnected,
                isUserEnabled: domain.userEnabled,
                knownFolderSyncState: Self.knownFolderSyncState(for: domain)
            )
        }
        #else
        return []
        #endif
    }

    func waitForStabilization(for configuration: ProviderDomainConfiguration) async throws {
        #if os(macOS)
        let domain = try await registeredDomain(for: configuration)
        Self.logger.info("wait for stabilization of domain(\(configuration.domainIdentifier, privacy: .public))")
        try await system.waitForStabilization(domain)
        #else
        throw ProviderDomainRegistrationError.externalVolumesUnsupported
        #endif
    }

    func removeDomainPreservingDirtyUserData(
        for configuration: ProviderDomainConfiguration
    ) async throws -> URL? {
        #if os(macOS)
        let domain = try await registeredDomain(for: configuration)
        Self.logger.info("remove domain preserving dirty user data(\(configuration.domainIdentifier, privacy: .public))")
        return try await system.removeDomainPreservingDirtyUserData(domain)
        #else
        throw ProviderDomainRegistrationError.externalVolumesUnsupported
        #endif
    }

    func reconnectDomain(for configuration: ProviderDomainConfiguration) async throws {
        #if os(macOS)
        let domain = try await registeredDomain(for: configuration)
        Self.logger.info("reconnect domain(\(configuration.domainIdentifier, privacy: .public))")
        try await system.reconnectDomain(domain)
        #else
        throw ProviderDomainRegistrationError.externalVolumesUnsupported
        #endif
    }

    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState] {
        #if os(macOS)
        let domains = try await registeredDomains()
        return Dictionary(uniqueKeysWithValues: domains.map { domain in
            (domain.identifier.rawValue, Self.knownFolderSyncState(for: domain))
        })
        #else
        return [:]
        #endif
    }

    func claimKnownFolders(for configuration: ProviderDomainConfiguration, parentFileID: Int) async throws {
        #if os(macOS)
        let manager = try await manager(for: configuration)
        let locations = Self.makeKnownFolderLocations(parentFileID: parentFileID)
        let reason = "Keep your Desktop & Documents in sync with \(configuration.displayName) in kDrive."

        Self.logger.info("claim known folders for domain(\(configuration.domainIdentifier, privacy: .public)) parentFileID(\(parentFileID, privacy: .public))")
        try await manager.claimKnownFolders(locations, localizedReason: reason)
        Self.logger.info("claimed known folders for domain(\(configuration.domainIdentifier, privacy: .public))")
        #else
        throw ProviderKnownFolderRegistrationError.unsupportedPlatform
        #endif
    }

    func releaseKnownFolders(for configuration: ProviderDomainConfiguration) async throws {
        #if os(macOS)
        let manager = try await manager(for: configuration)
        let reason = "Stop syncing Desktop & Documents with \(configuration.displayName) in kDrive."

        Self.logger.info("release known folders for domain(\(configuration.domainIdentifier, privacy: .public))")
        try await manager.releaseKnownFolders([.desktop, .documents], localizedReason: reason)
        Self.logger.info("released known folders for domain(\(configuration.domainIdentifier, privacy: .public))")
        #else
        throw ProviderKnownFolderRegistrationError.unsupportedPlatform
        #endif
    }

    func makeDomain(for configuration: ProviderDomainConfiguration) -> NSFileProviderDomain {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: configuration.domainIdentifier),
            displayName: configuration.displayName
        )
        #if os(macOS)
        domain.supportedKnownFolders = [.desktop, .documents]
        #endif
        return domain
    }

    private func domainForExistingOperation(
        _ configuration: ProviderDomainConfiguration
    ) async throws -> NSFileProviderDomain {
        switch configuration.storageLocation {
        case .onThisMac:
            return makeDomain(for: configuration)
        case .externalVolume:
            #if os(macOS)
            return try await registeredDomain(for: configuration)
            #else
            throw ProviderDomainRegistrationError.externalVolumesUnsupported
            #endif
        }
    }

    #if os(macOS)
    static func makeKnownFolderLocations(parentFileID: Int) -> NSFileProviderKnownFolderLocations {
        let parentIdentifier = NSFileProviderItemIdentifier(KDriveItemIdentifier.item(parentFileID).rawValue)
        let locations = NSFileProviderKnownFolderLocations()
        locations.desktopLocation = NSFileProviderKnownFolderLocations.Location(
            parentItemIdentifier: parentIdentifier,
            filename: "Desktop"
        )
        locations.documentsLocation = NSFileProviderKnownFolderLocations.Location(
            parentItemIdentifier: parentIdentifier,
            filename: "Documents"
        )
        return locations
    }

    private func manager(for configuration: ProviderDomainConfiguration) async throws -> NSFileProviderManager {
        let domain = try await registeredDomain(for: configuration)
        guard let manager = NSFileProviderManager(for: domain) else {
            throw ProviderKnownFolderRegistrationError.managerUnavailable(configuration.domainIdentifier)
        }
        return manager
    }

    private func registeredDomains() async throws -> [NSFileProviderDomain] {
        try await system.registeredDomains()
    }

    private func registeredDomain(
        for configuration: ProviderDomainConfiguration
    ) async throws -> NSFileProviderDomain {
        let identifier = NSFileProviderDomainIdentifier(rawValue: configuration.domainIdentifier)
        guard let domain = try await registeredDomains().first(where: { $0.identifier == identifier }) else {
            throw ProviderDomainRegistrationError.domainNotRegistered(configuration.domainIdentifier)
        }
        return domain
    }

    private static func knownFolderSyncState(
        for domain: NSFileProviderDomain
    ) -> ProviderKnownFolderSyncState {
        let folders = domain.replicatedKnownFolders
        if folders.contains(.desktop), folders.contains(.documents) {
            return .active
        } else if folders.contains(.desktop) || folders.contains(.documents) {
            return .partial
        } else {
            return .inactive
        }
    }
    #endif
}

@MainActor
struct FileProviderDomainSystemClient {
    var addDomain: (NSFileProviderDomain) async throws -> Void
    var removeDomain: (NSFileProviderDomain) async throws -> Void
    var registeredDomains: () async throws -> [NSFileProviderDomain]
    var waitForStabilization: (NSFileProviderDomain) async throws -> Void
    var removeDomainPreservingDirtyUserData: (NSFileProviderDomain) async throws -> URL?
    var reconnectDomain: (NSFileProviderDomain) async throws -> Void

    static let live = FileProviderDomainSystemClient(
        addDomain: { domain in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSFileProviderManager.add(domain) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        },
        removeDomain: { domain in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSFileProviderManager.remove(domain) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        },
        registeredDomains: {
            try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: domains)
                    }
                }
            }
        },
        waitForStabilization: { domain in
            guard let manager = NSFileProviderManager(for: domain) else {
                throw ProviderDomainRegistrationError.managerUnavailable(domain.identifier.rawValue)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.waitForStabilization { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        },
        removeDomainPreservingDirtyUserData: { domain in
            #if os(macOS)
            return try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.remove(domain, mode: .preserveDirtyUserData) { preservedLocation, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: preservedLocation)
                    }
                }
            }
            #else
            throw ProviderDomainRegistrationError.externalVolumesUnsupported
            #endif
        },
        reconnectDomain: { domain in
            #if os(macOS)
            guard let manager = NSFileProviderManager(for: domain) else {
                throw ProviderDomainRegistrationError.managerUnavailable(domain.identifier.rawValue)
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                manager.reconnect { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            #else
            throw ProviderDomainRegistrationError.externalVolumesUnsupported
            #endif
        }
    )
}

enum ProviderDomainRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case externalVolumesUnsupported
    case preparedDomainUnsupported
    case stabilizationUnsupported
    case reconnectionUnsupported
    case domainNotRegistered(String)
    case managerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .externalVolumesUnsupported:
            return "External File Provider storage is available only on macOS."
        case .preparedDomainUnsupported:
            return "This File Provider registrar cannot prepare domains."
        case .stabilizationUnsupported:
            return "This File Provider registrar cannot wait for domain stabilization."
        case .reconnectionUnsupported:
            return "This File Provider registrar cannot reconnect domains."
        case .domainNotRegistered:
            return "The selected kDrive is not registered with File Provider."
        case .managerUnavailable:
            return "File Provider could not open the selected kDrive domain."
        }
    }
}

enum ProviderKnownFolderRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedPlatform
    case domainNotRegistered(String)
    case managerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Desktop and Documents synchronization is available only on macOS."
        case .domainNotRegistered:
            return "The selected kDrive is not registered with File Provider."
        case .managerUnavailable:
            return "File Provider could not open the selected kDrive domain."
        }
    }
}
