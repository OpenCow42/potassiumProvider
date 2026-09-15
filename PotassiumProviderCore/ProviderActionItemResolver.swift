import FileProvider
import Foundation

/// Translates FileProviderUI's opaque selection through the system namespace.
/// Never interprets a macOS document ID, a filename, or a local path as a server ID.
public struct ProviderActionItemResolver: Sendable {
    public typealias Completion<Value: Sendable> = @Sendable (Result<Value, Error>) -> Void
    public struct Binding: Sendable {
        public let itemIdentifier: String
        public let domainIdentifier: String
        public init(itemIdentifier: String, domainIdentifier: String) {
            self.itemIdentifier = itemIdentifier
            self.domainIdentifier = domainIdentifier
        }
    }

    private let visibleURL: @Sendable (String, @escaping Completion<URL>) -> Void
    private let identifier: @Sendable (URL, @escaping Completion<Binding>) -> Void

    public init(
        visibleURL: @escaping @Sendable (String, @escaping Completion<URL>) -> Void,
        identifier: @escaping @Sendable (URL, @escaping Completion<Binding>) -> Void
    ) {
        self.visibleURL = visibleURL
        self.identifier = identifier
    }

    public func resolve(
        _ selection: String, domainIdentifier: String, engine: ProviderEncryptionMode,
        timeout: Duration = .seconds(90)
    ) async throws -> String {
        try Task.checkCancellation()
        guard engine != .opaqueVaultV1 else { throw ProviderActionItemResolutionError.invalidIdentifier }
        let deadline = StabilityDeadline(budget: timeout)
        do {
            let url = try await StabilityCallbackWaiter<URL>().wait(timeout: deadline.remaining()) { completion in
                visibleURL(selection, completion)
            }
            try Task.checkCancellation()
            guard url.isFileURL else { throw ProviderActionItemResolutionError.unavailable }
            // No contents are read and no URL is retained. Balance the security scope
            // while asking the system to resolve the URL back into its provider domain.
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let binding = try await StabilityCallbackWaiter<Binding>().wait(timeout: deadline.remaining()) { completion in
                identifier(url, completion)
            }
            try Task.checkCancellation()
            guard binding.domainIdentifier == domainIdentifier else { throw ProviderActionItemResolutionError.domainMismatch }
            let resolved = try Self.validate(binding.itemIdentifier, engine: engine)
            if let canonicalSelection = try? Self.validate(selection, engine: engine), canonicalSelection != resolved {
                throw ProviderActionItemResolutionError.invalidIdentifier
            }
            return resolved
        } catch is CancellationError {
            throw CancellationError()
        } catch StabilityDeadlineError.expired {
            throw ProviderActionItemResolutionError.timedOut
        } catch let error as ProviderActionItemResolutionError {
            throw error
        } catch {
            // System errors can contain user-visible URLs and private identifiers.
            throw ProviderActionItemResolutionError.unavailable
        }
    }

    public static func validate(_ identifier: String, engine: ProviderEncryptionMode) throws -> String {
        switch engine {
        case .legacyPlaintext:
            guard let parsed = try? KDriveItemIdentifier(rawValue: identifier),
                  parsed == .root || parsed.fileID != nil else { throw ProviderActionItemResolutionError.invalidIdentifier }
        case .opaqueVaultV2:
            guard VaultItemIdentifier(fileProviderIdentifier: identifier) != nil else { throw ProviderActionItemResolutionError.invalidIdentifier }
        case .opaqueVaultV1:
            throw ProviderActionItemResolutionError.invalidIdentifier
        }
        return identifier
    }

    public static func resolve(
        _ selection: NSFileProviderItemIdentifier, configuration: ProviderDomainConfiguration
    ) async throws -> NSFileProviderItemIdentifier {
        #if os(macOS)
        let domain = NSFileProviderDomain(identifier: .init(configuration.domainIdentifier), displayName: configuration.displayName)
        guard let manager = NSFileProviderManager(for: domain) else { throw ProviderActionItemResolutionError.unavailable }
        let resolver = Self(visibleURL: { selection, completion in
            manager.getUserVisibleURL(for: .init(selection)) { url, error in
                if let error { completion(.failure(error)) }
                else if let url { completion(.success(url)) }
                else { completion(.failure(ProviderActionItemResolutionError.unavailable)) }
            }
        }, identifier: { url, completion in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { item, domain, error in
                if let error { completion(.failure(error)) }
                else if let item, let domain {
                    completion(.success(.init(itemIdentifier: item.rawValue, domainIdentifier: domain.rawValue)))
                } else { completion(.failure(ProviderActionItemResolutionError.unavailable)) }
            }
        })
        let identifier = try await resolver.resolve(selection.rawValue, domainIdentifier: configuration.domainIdentifier, engine: configuration.encryptionMode)
        return .init(identifier)
        #else
        // Replicated iOS extensions cannot obtain user-visible URLs. Files supplies
        // provider identifiers; reject unknown identifiers without a path fallback.
        try Task.checkCancellation()
        return try .init(validate(selection.rawValue, engine: configuration.encryptionMode))
        #endif
    }
}

public enum ProviderActionItemResolutionError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier, domainMismatch, unavailable, timedOut
    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier, .domainMismatch, .unavailable:
            "The selected item could not be identified in this File Provider domain. Close this action and select the item again."
        case .timedOut:
            "Identifying the selected item timed out. Close this action and try again."
        }
    }
}
