import FileProvider
import Foundation
import PotassiumProviderCore

@MainActor
protocol ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws
}

@MainActor
struct FileProviderDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: configuration.domainIdentifier),
            displayName: configuration.displayName
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
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

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
