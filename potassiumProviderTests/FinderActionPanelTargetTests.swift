#if os(macOS) && STABILITY
import Foundation
import Testing
@testable import potassiumProvider

struct FinderActionPanelTargetTests {
    let expected = URL(fileURLWithPath: "/tmp/Chosen.app/Contents/PlugIns/Actions.appex/Contents/MacOS/Actions")
    let alias = "provider.stability.action." + UUID().uuidString

    @Test func attestsBothPhysicalExecutableAndCode() {
        #expect(FinderActionPanelTarget.isExpectedProcess(executableURL: expected, expectedURL: expected, codeHash: "new", expectedCodeHash: "new"))
        #expect(!FinderActionPanelTarget.isExpectedProcess(executableURL: expected, expectedURL: expected, codeHash: "old", expectedCodeHash: "new"))
        #expect(!FinderActionPanelTarget.isExpectedProcess(executableURL: URL(fileURLWithPath: "/tmp/Older.app/Actions"), expectedURL: expected, codeHash: "new", expectedCodeHash: "new"))
        #expect(!FinderActionPanelTarget.isExpectedProcess(executableURL: nil, expectedURL: expected, codeHash: "new", expectedCodeHash: "new"))
        #expect(!FinderActionPanelTarget.isExpectedProcess(executableURL: expected, expectedURL: expected, codeHash: nil, expectedCodeHash: nil))
    }

    @Test func mainWindowOnlyDiscoveryStillRequiresExactAliasAndDeduplicatesListedWindow() {
        #expect(FinderActionPanelTarget.candidates(listed: [Int](), main: 7, equal: ==) == [7])
        #expect(FinderActionPanelTarget.candidates(listed: [7], main: 7, equal: ==) == [7])
        #expect(FinderActionPanelTarget.candidates(listed: [8], main: 7, equal: ==) == [8, 7])
        #expect(FinderActionPanelTarget.candidates(listed: [Int](), main: nil, equal: ==).isEmpty)
        let discovered = FinderActionPanelTarget.candidates(listed: [[String]](), main: ["unrelated"], equal: ==)
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: discovered) == nil)
    }

    @Test func requiresOnePanelWithTheExactFixtureAlias() {
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: [["unrelated"], [alias]]) == 1)
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: [[alias], [alias]]) == nil)
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: [["Action Unavailable"], ["provider.stability.action.unbound"]]) == nil)
        #expect(FinderActionPanelTarget.index(alias: "provider.stability.action.unbound", windowIdentifiers: [["provider.stability.action.unbound"]]) == nil)
    }

    @Test func twoHostsOfTheSameRemotePanelResolveToTheLastAttestedWindow() {
        #expect(FinderActionPanelTarget.windowIndex(alias: alias, panels: [[7], [7]],
            identifier: { _ in alias }, equal: ==) == 1)
        #expect(FinderActionPanelTarget.windowIndex(alias: alias, panels: [[7], []],
            identifier: { _ in alias }, equal: ==) == 0)
    }

    @Test func detachedMainWindowCannotKeepADismissedPanelBound() {
        #expect(FinderActionPanelTarget.windowIndex(alias: alias, panels: [[], [7]],
            identifier: { _ in alias }, equal: ==) == nil)
    }

    @Test func distinctPanelsWithTheSameAliasRemainAmbiguousAcrossOrWithinWindows() {
        for panels in [[[7], [8]], [[7, 8]], [[7], [7, 8]]] {
            #expect(FinderActionPanelTarget.windowIndex(alias: alias, panels: panels,
                identifier: { _ in alias }, equal: ==) == nil)
        }
        #expect(FinderActionPanelTarget.windowIndex(alias: alias, panels: [[7]],
            identifier: { _ in "unrelated" }, equal: ==) == nil)
        #expect(FinderActionPanelTarget.windowIndex(alias: "provider.stability.action.unbound", panels: [[7]],
            identifier: { _ in "provider.stability.action.unbound" }, equal: ==) == nil)
    }
}
#endif
