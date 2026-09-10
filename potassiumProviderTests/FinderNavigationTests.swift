#if os(macOS) && STABILITY
import Foundation
import CoreGraphics
import Testing
@testable import potassiumProvider

@MainActor
@Suite("Finder UI transitions")
struct FinderNavigationTests {
    @Test func nameEditorRequiresExactSelectionLabelAndOwnedWindowGeometry() {
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        let field = CGRect(x: 250, y: 200, width: 150, height: 20)
        #expect(FinderNameEditorObservation.isConfined(value: "New Folder", expected: "New Folder", editorBounds: field,
            windowBounds: window, sameProcess: true, ownedWindowIsFront: true))
        #expect(!FinderNameEditorObservation.isConfined(value: "Other", expected: "New Folder", editorBounds: field,
            windowBounds: window, sameProcess: true, ownedWindowIsFront: true))
        #expect(!FinderNameEditorObservation.isConfined(value: "New Folder", expected: "New Folder", editorBounds: field.offsetBy(dx: 900, dy: 0),
            windowBounds: window, sameProcess: true, ownedWindowIsFront: true))
        #expect(!FinderNameEditorObservation.isConfined(value: "New Folder", expected: "New Folder", editorBounds: field,
            windowBounds: window, sameProcess: false, ownedWindowIsFront: true))
        #expect(!FinderNameEditorObservation.isConfined(value: "New Folder", expected: "New Folder", editorBounds: field,
            windowBounds: window, sameProcess: true, ownedWindowIsFront: false))
    }
    @Test func unrelatedBusyAlertsAreNotTreatedAsTheGeneratedEvictionResult() {
        #expect(FinderAlertObservation.isResourceBusyEviction(labels: ["Unable to Remove Download", "Resource busy", "OK"]))
        #expect(!FinderAlertObservation.isResourceBusyEviction(labels: ["Unable to Delete", "Resource busy", "OK"]))
        #expect(!FinderAlertObservation.isResourceBusyEviction(labels: ["Unable to Remove Download", "Permission denied", "OK"]))
    }
    @Test func windowCleanupClosesOnlyTheCreatedID() throws {
        let process = FinderProcessIdentity(pid: 12, launchedAt: Date(timeIntervalSince1970: 100))
        let ownership = FinderWindowOwnership(windowID: 42, process: process)
        var closed: [Int32] = []
        ownership.close(currentProcess: process) { closed.append($0) }
        #expect(closed == [42])
    }

    @Test func windowCleanupRejectsRelaunchedFinderEvenWhenPIDAndWindowIDAreReused() {
        let original = FinderProcessIdentity(pid: 12, launchedAt: Date(timeIntervalSince1970: 100))
        let replacement = FinderProcessIdentity(pid: 12, launchedAt: Date(timeIntervalSince1970: 200))
        let ownership = FinderWindowOwnership(windowID: 42, process: original)
        var closed = false
        ownership.close(currentProcess: replacement) { _ in closed = true }
        ownership.close(currentProcess: nil) { _ in closed = true }
        #expect(!closed)
    }

    @Test func windowCleanupFailureRemainsObservable() {
        let process = FinderProcessIdentity(pid: 12, launchedAt: Date(timeIntervalSince1970: 100))
        let ownership = FinderWindowOwnership(windowID: 42, process: process)
        #expect(throws: FinderUIError.automationFailed) {
            try ownership.close(currentProcess: process) { _ in throw FinderUIError.automationFailed }
        }
    }
    @Test func localURLIdentityAcceptsCanonicalSpellingButRejectsOtherTargets() {
        let expected = URL(filePath: "/synthetic/café.txt")
        #expect(FinderUIURLIdentity.matches(URL(string: "file://localhost/synthetic/caf%C3%A9.txt"), expected))
        #expect(FinderUIURLIdentity.matches(URL(filePath: "/synthetic/cafe\u{301}.txt"), expected))
        #expect(!FinderUIURLIdentity.matches(URL(filePath: "/synthetic/other.txt"), expected))
        #expect(!FinderUIURLIdentity.matches(URL(string: "file://different-host/synthetic/caf%C3%A9.txt"), expected))
        #expect(!FinderUIURLIdentity.matches(nil, expected))
    }

    @Test func unavailableRowCannotTriggerSelection() async {
        var assigned = false
        await #expect(throws: FinderUIError.timedOut) {
            try await FinderSelectionSequence.execute(waitUntilVisible: { throw FinderUIError.timedOut },
                assignSelection: { assigned = true }, waitUntilSelected: {})
        }
        #expect(!assigned)
    }

    @Test func ignoredSelectionCannotCompleteTheSelectionSequence() async {
        await #expect(throws: FinderUIError.selectionMismatch) {
            try await FinderSelectionSequence.execute(waitUntilVisible: {}, assignSelection: {},
                waitUntilSelected: { throw FinderUIError.selectionMismatch })
        }
    }
    @Test func hiddenExtensionUsesExactDisplayedNameAndRejectsAmbiguousRows() {
        #expect(FinderUINameObservation.hasUniqueMatch(displayedName: "remote-change", rowNames: ["remote-change"]))
        #expect(!FinderUINameObservation.hasUniqueMatch(displayedName: "remote-change.txt", rowNames: ["remote-change"]))
        #expect(!FinderUINameObservation.hasUniqueMatch(displayedName: "remote-change", rowNames: ["remote-change", "remote-change"]))
        #expect(!FinderUINameObservation.hasUniqueMatch(displayedName: "", rowNames: [""]))
    }
    @Test func navigationVerifiesHistoryAndParentInOrder() async throws {
        let ui = NavigationFake()
        let root = URL(filePath: "/synthetic"), nested = URL(filePath: "/synthetic/a")
        let deep = URL(filePath: "/synthetic/a/b"), sibling = URL(filePath: "/synthetic/c")
        try await FinderNavigationSequence.execute(using: ui, root: root, nested: nested, deep: deep, sibling: sibling)
        #expect(ui.calls == [.navigate(root), .navigate(nested), .navigate(deep), .back(nested), .forward(deep), .parent(nested), .navigate(sibling)])
    }
    @Test func unexpectedWindowStopsNavigation() async {
        let ui = NavigationFake(); ui.rejectHistory = true
        let root = URL(filePath: "/synthetic")
        await #expect(throws: FinderUIError.windowMismatch) {
            try await FinderNavigationSequence.execute(using: ui, root: root, nested: root, deep: root, sibling: root)
        }
        #expect(ui.calls.count == 4)
    }
    @Test func fixtureChildrenResolveOnlyAfterTheirVerifiedParentIsOpened() async throws {
        let ui = NavigationFake()
        let root = URL(filePath: "/synthetic"), nested = URL(filePath: "/synthetic/a")
        let deep = URL(filePath: "/synthetic/a/b"), sibling = URL(filePath: "/synthetic/c")
        let seed = deep.appendingPathComponent("seed.txt")
        let result = try await FinderFixtureNavigation.resolve(using: ui) { target in
            let parent: URL?, result: URL
            switch target {
            case .root: (parent, result) = (nil, root)
            case .nested: (parent, result) = (root, nested)
            case .deep: (parent, result) = (nested, deep)
            case .sibling: (parent, result) = (root, sibling)
            case .seed: (parent, result) = (deep, seed)
            }
            if let parent, ui.calls.last != .navigate(parent) { throw FinderUIError.timedOut }
            return result
        }
        #expect(result.root == root && result.nested == nested && result.deep == deep && result.sibling == sibling && result.seed == seed)
    }
    @Test func failedFixtureBindingCannotNavigateOrResolveDescendants() async {
        let ui = NavigationFake(), root = URL(filePath: "/synthetic")
        var attempts = 0
        await #expect(throws: FinderUIError.selectionMismatch) {
            try await FinderFixtureNavigation.resolve(using: ui) { target in
                attempts += 1
                if target == .nested { throw FinderUIError.selectionMismatch }
                return root
            }
        }
        #expect(attempts == 2 && ui.calls == [.navigate(root)])
    }
    @Test func missingMilestoneEvidenceStopsBeforeFurtherNavigation() async {
        let ui = NavigationFake(), root = URL(filePath: "/synthetic")
        var observed: [Int] = []
        await #expect(throws: FinderUIError.screenshotUnavailable) {
            try await FinderNavigationSequence.execute(using: ui, root: root, nested: root, deep: root, sibling: root) { index, _ in
                observed.append(index)
                if index == 2 { throw FinderUIError.screenshotUnavailable }
            }
        }
        #expect(observed == [0, 1, 2])
        #expect(ui.calls.count == 3)
    }
}

@MainActor
private final class NavigationFake: FinderUINavigating {
    enum Call: Equatable { case navigate(URL), back(URL), forward(URL), parent(URL) }
    var calls: [Call] = []
    var rejectHistory = false
    func navigate(to url: URL) async throws { calls.append(.navigate(url)) }
    func navigateHistory(back: Bool, expectedURL: URL) async throws {
        calls.append(back ? .back(expectedURL) : .forward(expectedURL))
        if rejectHistory { throw FinderUIError.windowMismatch }
    }
    func navigateParent(expectedURL: URL) async throws { calls.append(.parent(expectedURL)) }
}
#endif
