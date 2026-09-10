#if os(macOS) && STABILITY
import PotassiumProviderCore

@MainActor
enum FinderRestoreObservation {
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
