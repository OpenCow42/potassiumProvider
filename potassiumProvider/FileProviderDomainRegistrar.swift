import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

@MainActor
protocol ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws
    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState]
    func claimKnownFolders(for configuration: ProviderDomainConfiguration, parentFileID: Int) async throws
    func releaseKnownFolders(for configuration: ProviderDomainConfiguration) async throws
}

enum ProviderKnownFolderSyncState: Equatable, Sendable {
    case unavailable
    case inactive
    case partial
    case active
}

extension ProviderDomainRegistering {
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

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        let domain = makeDomain(for: configuration)

        Self.logger.info("addDomain(\(configuration.domainIdentifier, privacy: .public)) displayName(\(configuration.displayName, privacy: .private)) driveID(\(configuration.driveID, privacy: .public))")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    Self.logger.error("failed to addDomain(\(configuration.domainIdentifier, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    Self.logger.info("added domain(\(configuration.domainIdentifier, privacy: .public)) to File Provider")
                    continuation.resume()
                }
            }
        }
    }

    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {
        let domain = makeDomain(for: configuration)

        Self.logger.info("removeDomain(\(configuration.domainIdentifier, privacy: .public)) displayName(\(configuration.displayName, privacy: .private))")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    Self.logger.error("failed to removeDomain(\(configuration.domainIdentifier, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                } else {
                    Self.logger.info("removed domain(\(configuration.domainIdentifier, privacy: .public)) from File Provider")
                    continuation.resume()
                }
            }
        }
    }

    func knownFolderSyncStates() async throws -> [String: ProviderKnownFolderSyncState] {
        #if os(macOS)
        let domains = try await registeredDomains()
        return Dictionary(uniqueKeysWithValues: domains.map { domain in
            let folders = domain.replicatedKnownFolders
            let state: ProviderKnownFolderSyncState
            if folders.contains(.desktop), folders.contains(.documents) {
                state = .active
            } else if folders.contains(.desktop) || folders.contains(.documents) {
                state = .partial
            } else {
                state = .inactive
            }
            return (domain.identifier.rawValue, state)
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
        let identifier = NSFileProviderDomainIdentifier(rawValue: configuration.domainIdentifier)
        guard let domain = try await registeredDomains().first(where: { $0.identifier == identifier }) else {
            throw ProviderKnownFolderRegistrationError.domainNotRegistered(configuration.domainIdentifier)
        }
        guard let manager = NSFileProviderManager(for: domain) else {
            throw ProviderKnownFolderRegistrationError.managerUnavailable(configuration.domainIdentifier)
        }
        return manager
    }

    private func registeredDomains() async throws -> [NSFileProviderDomain] {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: domains)
                }
            }
        }
    }
    #endif
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
