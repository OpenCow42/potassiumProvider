#if os(macOS) && STABILITY
import CoreGraphics
import Testing
@testable import potassiumProvider

struct FinderToolbarActionTargetTests {
    let window = CGRect(x: 0, y: 0, width: 500, height: 400)
    let toolbar = CGRect(x: 0, y: 0, width: 500, height: 60)
    let button = CGRect(x: 300, y: 10, width: 30, height: 30)

    @Test func choosesTheExactEnabledActionsControlWithinTheBoundToolbar() {
        #expect(FinderToolbarActionTarget.index(window: window, toolbar: toolbar, buttons: [
            .init(description: "Group", enabled: true, bounds: button),
            .init(description: "Action", enabled: true, bounds: button)]) == 1)
    }

    @Test func missingAmbiguousDisabledOrUnconfinedControlsFailClosed() {
        let valid = FinderToolbarActionTarget.Button(description: "Action", enabled: true, bounds: button)
        #expect(FinderToolbarActionTarget.index(window: window, toolbar: toolbar, buttons: []) == nil)
        #expect(FinderToolbarActionTarget.index(window: window, toolbar: toolbar, buttons: [valid, valid]) == nil)
        #expect(FinderToolbarActionTarget.index(window: window, toolbar: toolbar, buttons: [
            .init(description: "Action", enabled: false, bounds: button)]) == nil)
        #expect(FinderToolbarActionTarget.index(window: window, toolbar: toolbar, buttons: [
            .init(description: "Action", enabled: true, bounds: CGRect(x: 300, y: 80, width: 30, height: 30))]) == nil)
        #expect(FinderToolbarActionTarget.index(window: window, toolbar: toolbar.offsetBy(dx: 500, dy: 0), buttons: [valid]) == nil)
    }
}
#endif
