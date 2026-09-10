#if os(macOS) && STABILITY
import Foundation
import CoreGraphics

struct FinderProcessIdentity: Equatable {
    let pid: Int32
    let launchedAt: Date
}

struct FinderWindowOwnership {
    let windowID: Int32
    let process: FinderProcessIdentity

    func close(currentProcess: FinderProcessIdentity?, perform: (Int32) throws -> Void) rethrows {
        // Finder restart destroys its old windows; a reused ID belongs to the
        // new process and must not be touched by this run's cleanup.
        guard currentProcess == process else { return }
        try perform(windowID)
    }
}

enum FinderUIURLIdentity {
    static func matches(_ actual: URL?, _ expected: URL) -> Bool {
        guard let actual, actual.isFileURL, expected.isFileURL,
              [nil, "", "localhost"].contains(actual.host),
              [nil, "", "localhost"].contains(expected.host) else { return false }
        return actual.standardizedFileURL.path.precomposedStringWithCanonicalMapping ==
            expected.standardizedFileURL.path.precomposedStringWithCanonicalMapping
    }
}

enum FinderUINameObservation {
    static func hasUniqueMatch(displayedName: String, rowNames: [String]) -> Bool {
        !displayedName.isEmpty && rowNames.filter { $0 == displayedName }.count == 1
    }
}

enum FinderAlertObservation {
    static func isResourceBusyEviction(labels: [String]) -> Bool {
        labels.contains("Unable to Remove Download") && labels.contains {
            $0.localizedCaseInsensitiveContains("resource busy") || $0.localizedCaseInsensitiveContains("ressource busy")
        }
    }
}

enum FinderNameEditorObservation {
    static func isConfined(value: String?, expected: String, editorBounds: CGRect, windowBounds: CGRect,
                           sameProcess: Bool, ownedWindowIsFront: Bool) -> Bool {
        sameProcess && ownedWindowIsFront && !expected.isEmpty && value == expected &&
            editorBounds.width > 1 && editorBounds.height > 1 && windowBounds.contains(editorBounds)
    }
}
@MainActor
enum FinderSelectionSequence {
    static func execute(waitUntilVisible: () async throws -> Void,
                        assignSelection: () throws -> Void,
                        waitUntilSelected: () async throws -> Void) async throws {
        // Finder may acknowledge a new window target before its rows exist.
        // An early selection assignment is silently ignored and is not replayed.
        try await waitUntilVisible()
        try assignSelection()
        try await waitUntilSelected()
    }
}

@MainActor
enum FinderNavigationSequence {
    static func execute(using ui: any FinderUINavigating, root: URL, nested: URL, deep: URL, sibling: URL,
                        observe: ((Int, URL) async throws -> Void)? = nil) async throws {
        try await ui.navigate(to: root)
        try await observe?(0, root)
        try await ui.navigate(to: nested)
        try await observe?(1, nested)
        try await ui.navigate(to: deep)
        try await observe?(2, deep)
        try await ui.navigateHistory(back: true, expectedURL: nested)
        try await observe?(3, nested)
        try await ui.navigateHistory(back: false, expectedURL: deep)
        try await observe?(4, deep)
        try await ui.navigateParent(expectedURL: nested)
        try await observe?(5, nested)
        try await ui.navigate(to: sibling)
        try await observe?(6, sibling)
    }
}

@MainActor
enum FinderFixtureNavigation {
    enum Scope { case fullSuite, conflict }
    enum Target: String { case root, nested, deep, sibling, seed }

    /// A targeted race owns its navigation and hydration. Preparation binds only
    /// the run root so unrelated deep-hierarchy failures cannot block the race.
    static func resolveConflictRoot(using ui: any FinderUINavigating,
                                    bind: (Target) async throws -> URL) async throws -> URL {
        let root = try await bind(.root)
        try await ui.navigate(to: root)
        return root
    }

    /// Open each verified parent before asking File Provider to materialize its
    /// children. Resolving the entire unopened hierarchy can wait for separate
    /// working-set crawls at every level.
    static func resolve(using ui: any FinderUINavigating,
                        bind: (Target) async throws -> URL) async throws
        -> (root: URL, nested: URL, deep: URL, sibling: URL, seed: URL) {
        let root = try await bind(.root)
        try await ui.navigate(to: root)
        let nested = try await bind(.nested)
        try await ui.navigate(to: nested)
        let deep = try await bind(.deep)
        try await ui.navigate(to: deep)
        let seed = try await bind(.seed)
        try await ui.navigate(to: root)
        let sibling = try await bind(.sibling)
        return (root, nested, deep, sibling, seed)
    }
}
#endif
