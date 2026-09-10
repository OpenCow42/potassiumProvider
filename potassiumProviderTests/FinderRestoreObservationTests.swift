#if os(macOS) && STABILITY
import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@MainActor
@Suite("Finder Restore observation")
struct FinderRestoreObservationTests {
    @Test func staleTrashLocationOrWrongNameCannotProveVisibleRestoration() {
        let parent = URL(filePath: "/synthetic/run/Created Folder", directoryHint: .isDirectory)
        #expect(FinderRestoreObservation.matchesVisibleDestination(parent.appendingPathComponent("restored.txt"), parent: parent, name: "restored.txt"))
        #expect(!FinderRestoreObservation.matchesVisibleDestination(URL(filePath: "/synthetic/.Trash/restored.txt"), parent: parent, name: "restored.txt"))
        #expect(!FinderRestoreObservation.matchesVisibleDestination(parent.appendingPathComponent("different.txt"), parent: parent, name: "restored.txt"))
    }

    @Test func delayedMoveLocationCannotPassUntilParentAndNameBothMatch() async throws {
        let parent = URL(filePath: "/synthetic/run/Sibling", directoryHint: .isDirectory)
        let previous = URL(filePath: "/synthetic/run/conflict.txt")
        let final = parent.appendingPathComponent("conflict.txt")
        let pending = try await FinderRestoreObservation.observeVisibleDestination(parent: parent, name: "conflict.txt") { previous }
        #expect(pending == nil)
        let wrongName = try await FinderRestoreObservation.observeVisibleDestination(parent: parent, name: "conflict.txt") {
            parent.appendingPathComponent("another.txt")
        }
        #expect(wrongName == nil)
        let resolved = try await FinderRestoreObservation.observeVisibleDestination(parent: parent, name: "conflict.txt") { final }
        #expect(resolved == final)
        await #expect(throws: CancellationError.self) {
            try await FinderRestoreObservation.observeVisibleDestination(parent: parent, name: "conflict.txt") { throw CancellationError() }
        }
    }

    @Test func providerParentIdentityHandlesURLAliasesAndRejectsStaleParents() async throws {
        let candidate = URL(filePath: "/synthetic/mounted-alias/Sibling/conflict.txt")
        var checked: URL?
        let ready = try await FinderRestoreObservation.observeVisibleDestination(name: "conflict.txt", readVisible: { candidate }) { parent in
            checked = parent
            return FinderStabilityTargetBinding.matches(expectedFileID: 42, expectedDomainIdentifier: "synthetic-domain",
                actualItemIdentifier: "42", actualDomainIdentifier: "synthetic-domain")
        }
        #expect(ready == candidate && checked == candidate.deletingLastPathComponent())
        for (identifier, domain) in [("41", "synthetic-domain"), ("42", "different-domain")] {
            let pending = try await FinderRestoreObservation.observeVisibleDestination(name: "conflict.txt", readVisible: { candidate }) { _ in
                FinderStabilityTargetBinding.matches(expectedFileID: 42, expectedDomainIdentifier: "synthetic-domain",
                    actualItemIdentifier: identifier, actualDomainIdentifier: domain)
            }
            #expect(pending == nil)
        }
        let wrongName = try await FinderRestoreObservation.observeVisibleDestination(name: "different.txt", readVisible: { candidate }) { _ in true }
        #expect(wrongName == nil)
    }

    private func item(id: Int = 42, drive: Int = 7, parent: Int = 3) -> KDriveRemoteItem {
        KDriveRemoteItem(id: id, name: "Synthetic.txt", type: "file", status: "ok", driveID: drive,
            parentID: parent, path: nil, size: 4, mimeType: "text/plain", createdAt: nil,
            modifiedAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
    }

    @Test func missingCallbackCannotReleaseVerificationEvenWhenTheFileExists() async throws {
        var read = false
        let result = try await FinderRestoreObservation.observe(callbackCompleted: false, expected: item()) {
            read = true; return item()
        }
        #expect(result == nil)
        #expect(!read)
    }

    @Test func active404RemainsPendingUntilTheRestoredIdentityAppears() async throws {
        let expected = item()
        let pending = try await FinderRestoreObservation.observe(callbackCompleted: true, expected: expected) {
            throw APIClientError.unacceptableStatusCode(404, body: "synthetic")
        }
        #expect(pending == nil)
        let ready = try await FinderRestoreObservation.observe(callbackCompleted: true, expected: expected) { expected }
        #expect(ready == expected)
    }

    @Test(arguments: [401, 403, 429, 500])
    func operationalErrorsRemainFailures(_ status: Int) async {
        await #expect(throws: APIClientError.self) {
            try await FinderRestoreObservation.observe(callbackCompleted: true, expected: item()) {
                throw APIClientError.unacceptableStatusCode(status, body: "synthetic")
            }
        }
    }

    @Test func differentIdentityDriveOrDestinationCannotPass() async {
        for wrong in [item(id: 43), item(drive: 8), item(parent: 4)] {
            await #expect(throws: FinderLiveError.unsafeTarget) {
                try await FinderRestoreObservation.observe(callbackCompleted: true, expected: item()) { wrong }
            }
        }
    }
}
#endif
