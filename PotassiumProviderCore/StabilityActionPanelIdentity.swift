#if STABILITY
import Foundation

/// Disk-backed run discovery must not execute in SwiftUI layout or a Combine
/// subscriber on the main actor. The bounded waiter also ignores late disk replies.
public enum StabilityActionPanelIdentity {
    public static func resolve(
        for identifier: String,
        timeout: Duration = .seconds(90),
        lookup: @escaping @Sendable (String) -> UUID? = { StabilityDiagnosticIdentity.activeAlias(for: $0) }
    ) async throws -> UUID? {
        try Task.checkCancellation()
        return try await StabilityCallbackWaiter<UUID?>().wait(timeout: timeout) { completion in
            Task.detached(priority: .utility) {
                completion(.success(lookup(identifier)))
            }
        }
    }
}
#endif
