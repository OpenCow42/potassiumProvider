import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

@MainActor
protocol ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws
}

@MainActor
struct FileProviderDomainRegistrar: ProviderDomainRegistering {
    nonisolated private static let logger = Logger(subsystem: ProviderConstants.logSubsystem, category: "domain")

    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: configuration.domainIdentifier),
            displayName: configuration.displayName
        )

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
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: configuration.domainIdentifier),
            displayName: configuration.displayName
        )

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
}
