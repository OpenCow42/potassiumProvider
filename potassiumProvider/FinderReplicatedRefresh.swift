#if os(macOS) && STABILITY
import FileProvider

@MainActor
enum FinderReplicatedRefresh {
    /// NSFileProviderReplicatedExtension ignores native signals for individual
    /// containers. One working-set signal covers the completed mutation batch.
    static func signal(changedContainers: [NSFileProviderItemIdentifier],
                       recordSubject: (NSFileProviderItemIdentifier) -> Void = { _ in },
                       using signal: (NSFileProviderItemIdentifier) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !changedContainers.isEmpty else { return }
        // The native refresh target covers the entire domain, but the scenario
        // owns only its intended fixtures. Global monitoring settles other work.
        for identifier in changedContainers { recordSubject(identifier) }
        try await signal(.workingSet)
    }
}
#endif
