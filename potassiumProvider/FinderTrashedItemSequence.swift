#if os(macOS) && STABILITY
import Foundation

@MainActor
enum FinderTrashedItemSequence {
    /// Navigation can take time. Bind the exact provider identity again after
    /// revealing its parent and before any selected-item action.
    static func execute(reveal: () async throws -> Void,
                        revalidate: () async throws -> Void,
                        action: () async throws -> Void) async throws {
        try await reveal()
        try await revalidate()
        try await action()
    }
}
#endif
