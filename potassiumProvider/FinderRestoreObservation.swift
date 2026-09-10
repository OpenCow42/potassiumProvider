#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore

@MainActor
enum FinderRestoreObservation {
    static func matchesVisibleDestination(_ url: URL, parent: URL, name: String) -> Bool {
        FinderUIURLIdentity.matches(url.deletingLastPathComponent(), parent) &&
            url.lastPathComponent.precomposedStringWithCanonicalMapping == name.precomposedStringWithCanonicalMapping
    }

    static func observeVisibleDestination(parent: URL, name: String,
                                          readVisible: () async throws -> URL) async throws -> URL? {
        let candidate = try await readVisible()
        return matchesVisibleDestination(candidate, parent: parent, name: name) ? candidate : nil
    }

    /// A completed UI-originated callback gates verification. Active-item 404
    /// while restoration becomes visible is pending, never positive evidence.
    static func observe(callbackCompleted: Bool, expected: KDriveRemoteItem,
                        readActive: () async throws -> KDriveRemoteItem) async throws -> KDriveRemoteItem? {
        guard callbackCompleted else { return nil }
        do {
            let current = try await readActive()
            guard current.id == expected.id, current.driveID == expected.driveID,
                  current.parentID == expected.parentID else { throw FinderLiveError.unsafeTarget }
            return current
        } catch where KDriveRemoteErrorClassifier.isNotFound(error) {
            return nil
        }
    }
}
#endif
