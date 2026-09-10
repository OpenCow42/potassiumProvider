#if os(macOS) && STABILITY
import FileProvider

@MainActor
enum FinderReplicatedRefresh {
    /// NSFileProviderReplicatedExtension ignores native signals for individual
    /// containers. One working-set signal covers the completed mutation batch.
    static func signal(changedContainers: [NSFileProviderItemIdentifier],
                       using signal: (NSFileProviderItemIdentifier) async throws -> Void) async throws {
        try Task.checkCancellation()
        guard !changedContainers.isEmpty else { return }
        try await signal(.workingSet)
    }
}
#endif
