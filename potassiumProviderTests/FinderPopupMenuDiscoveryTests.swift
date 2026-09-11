#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

@MainActor
struct FinderPopupMenuDiscoveryTests {
    @Test func expandedSubmenuDoesNotHideItsRootOrExposeMenuBarCommands() {
        // App -> popup -> Open With -> submenu; app also has a menu bar.
        let children = [0: [1, 4], 1: [2], 2: [3], 4: [5], 5: [6]]
        let menus = Set([1, 3, 6])
        let roots = FinderPopupMenuDiscovery.roots(from: 0,
            role: { $0 == 4 ? .menuBar : menus.contains($0) ? .menu : .other },
            children: { children[$0] ?? [] }, visible: { _ in true })
        #expect(roots == [1])
    }

    @Test func twoIndependentPopupsRemainAmbiguous() {
        let roots = FinderPopupMenuDiscovery.roots(from: 0, role: { $0 == 0 ? .other : .menu },
            children: { $0 == 0 ? [1, 2] : [] }, visible: { _ in true })
        #expect(roots.count == 2)
    }

    @Test func hiddenMenuAndTraversalExhaustionFailClosed() {
        #expect(FinderPopupMenuDiscovery.roots(from: 0, role: { _ in .menu },
            children: { _ in [1] }, visible: { _ in false }).isEmpty)
        #expect(FinderPopupMenuDiscovery.roots(from: 0, limit: 2, role: { _ in .other },
            children: { _ in [0] }, visible: { _ in true }).isEmpty)
    }
}
#endif
