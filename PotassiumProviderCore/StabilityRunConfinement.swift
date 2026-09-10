import Foundation

public enum StabilityRunConfinementError: Error, Equatable { case unownedTarget, identityDrift, invalidAncestry }

public enum StabilityRunConfinement {
    /// Re-fetch every link: a cached URL or previously observed parent is never
    /// authority to mutate an item after it moved outside this run's subtree.
    public static func verify(targetID: Int, runRootID: Int, labRootID: Int, driveID: Int,
                              ownedIDs: Set<Int>, lookup: @Sendable (Int) async throws -> KDriveRemoteItem) async throws {
        guard targetID != labRootID, runRootID != labRootID, ownedIDs.contains(targetID), ownedIDs.contains(runRootID) else {
            throw StabilityRunConfinementError.unownedTarget
        }
        var cursor = targetID, seen: Set<Int> = []
        while seen.count < 16 && seen.insert(cursor).inserted {
            let item = try await lookup(cursor)
            guard item.id == cursor, item.driveID == driveID else { throw StabilityRunConfinementError.identityDrift }
            if cursor == runRootID {
                guard item.parentID == labRootID, item.isDirectory else { throw StabilityRunConfinementError.invalidAncestry }
                return
            }
            guard ownedIDs.contains(item.parentID) else { throw StabilityRunConfinementError.invalidAncestry }
            cursor = item.parentID
        }
        throw StabilityRunConfinementError.invalidAncestry
    }
}
