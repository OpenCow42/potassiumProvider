import Foundation
import PotassiumProviderCore
import Testing

@Suite("Live run target confinement")
struct StabilityRunConfinementTests {
    @Test func acceptsFreshOwnedAncestry() async throws {
        let items = [10: item(10, parent: 2), 11: item(11, parent: 10), 12: item(12, parent: 11)]
        try await verify(12, items: items)
    }

    @Test func rejectsLabRootAndUnownedSelection() async {
        for target in [2, 99] {
            await #expect(throws: StabilityRunConfinementError.unownedTarget) {
                try await verify(target, items: [10: item(10, parent: 2)])
            }
        }
    }

    @Test func rejectsAnOwnedItemMovedOutsideTheRun() async {
        let items = [10: item(10, parent: 2), 12: item(12, parent: 99)]
        await #expect(throws: StabilityRunConfinementError.invalidAncestry) {
            try await verify(12, items: items)
        }
    }

    @Test func rejectsChangedIdentityOrDrive() async {
        for replacement in [item(13, parent: 10), item(12, parent: 10, drive: 8)] {
            await #expect(throws: StabilityRunConfinementError.identityDrift) {
                try await verify(12, items: [10: item(10, parent: 2), 12: replacement])
            }
        }
    }

    @Test func rejectsCyclesAndDisplacedRunRoot() async {
        for items in [
            [10: item(10, parent: 2), 11: item(11, parent: 12), 12: item(12, parent: 11)],
            [10: item(10, parent: 99), 12: item(12, parent: 10)],
            [10: item(10, parent: 2, directory: false), 12: item(12, parent: 10)]
        ] {
            await #expect(throws: StabilityRunConfinementError.invalidAncestry) {
                try await verify(12, items: items)
            }
        }
    }

    private func verify(_ target: Int, items: [Int: KDriveRemoteItem]) async throws {
        try await StabilityRunConfinement.verify(targetID: target, runRootID: 10, labRootID: 2,
            driveID: 7, ownedIDs: [10, 11, 12]) { identifier in
                try #require(items[identifier])
            }
    }

    private func item(_ id: Int, parent: Int, drive: Int = 7, directory: Bool = true) -> KDriveRemoteItem {
        KDriveRemoteItem(id: id, name: "synthetic", type: directory ? "dir" : "file", status: "active",
            driveID: drive, parentID: parent, path: nil, size: nil, mimeType: nil,
            createdAt: nil, modifiedAt: .distantPast, updatedAt: .distantPast)
    }
}
