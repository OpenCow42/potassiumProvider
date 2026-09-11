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

    @Test func requiresOnePanelWithTheExactFixtureAlias() {
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: [["unrelated"], [alias]]) == 1)
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: [[alias], [alias]]) == nil)
        #expect(FinderActionPanelTarget.index(alias: alias, windowIdentifiers: [["Action Unavailable"], ["provider.stability.action.unbound"]]) == nil)
        #expect(FinderActionPanelTarget.index(alias: "provider.stability.action.unbound", windowIdentifiers: [["provider.stability.action.unbound"]]) == nil)
    }
}
#endif
