#if os(macOS) && STABILITY
import Foundation
import Testing
@testable import potassiumProvider

@MainActor
struct FinderHydrationSequenceTests {
    @Test func inspectedFixtureReleasesItsPresenterWithoutClosingUnrelatedDocuments() async throws {
        let ui = HydrationDocumentProbe()
        let fixture = URL(filePath: "/synthetic/run/remote-seed.txt")
        var inspected = false
        try await FinderHydrationSequence.execute(using: ui, url: fixture) {
            #expect(ui.presentedFixture == fixture)
            inspected = true
        }
        #expect(inspected)
        #expect(ui.presentedFixture == nil)
        #expect(ui.unrelatedDocumentIsOpen)
        try ui.requestEviction() // An open generated presenter rejects eviction.
        #expect(ui.evicted)
    }

    @Test func failedPresenterReleaseCannotCompleteHydration() async {
        let ui = HydrationDocumentProbe(failClose: true)
        var inspected = false
        await #expect(throws: HydrationDocumentProbe.Failure.closeFailed) {
            try await FinderHydrationSequence.execute(using: ui, url: URL(filePath: "/synthetic/run/remote-seed.txt")) {
                inspected = true
            }
        }
        #expect(inspected && ui.presentedFixture != nil)
        #expect(throws: HydrationDocumentProbe.Failure.resourceBusy) { try ui.requestEviction() }
        #expect(!ui.evicted && ui.unrelatedDocumentIsOpen)
    }
}

@MainActor
private final class HydrationDocumentProbe: FinderDocumentUIDriving {
    enum Failure: Error { case closeFailed, resourceBusy }
    let failClose: Bool
    private(set) var presentedFixture: URL?
    private(set) var evicted = false
    let unrelatedDocumentIsOpen = true
    init(failClose: Bool = false) { self.failClose = failClose }
    func edit(_ url: URL, contents: String?) async throws { presentedFixture = url }
    func closeOwnedEditorDocuments() async throws {
        if failClose { throw Failure.closeFailed }
        presentedFixture = nil
    }
    func requestEviction() throws {
        guard presentedFixture == nil else { throw Failure.resourceBusy }
        evicted = true
    }
}
#endif
