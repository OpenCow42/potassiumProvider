#if os(macOS) && STABILITY
import Foundation
import CoreGraphics
import Testing
@testable import potassiumProvider

@MainActor
struct FinderContextMenuTargetTests {
    let window = CGRect(x: 100, y: 100, width: 600, height: 400)
    let field = CGRect(x: 150, y: 150, width: 100, height: 20)

    @Test func exactDisplayNameAllowsSecondaryClickWithoutAnAXMenuAction() {
        // This is the field state observed live: a label and bounds, with no
        // advertised AXShowMenu. URL/domain/selection binding precedes this input.
        #expect(FinderContextMenuTarget.point(displayedName: "Generated", windowBounds: window,
            fields: [.init(name: "Generated", bounds: field)]) == CGPoint(x: 200, y: 160))
    }

    @Test func missingAmbiguousOrDifferentNamesCannotBroadenTheSelection() {
        let candidates: [[FinderContextMenuTarget.Field]] = [[], [.init(name: nil, bounds: field)],
            [.init(name: "Generated.txt", bounds: field)],
            [.init(name: "Generated", bounds: field), .init(name: "Generated", bounds: nil)]]
        for fields in candidates {
            #expect(FinderContextMenuTarget.point(displayedName: "Generated", windowBounds: window, fields: fields) == nil)
        }
        #expect(FinderContextMenuTarget.point(displayedName: "", windowBounds: window,
            fields: [.init(name: "", bounds: field)]) == nil)
    }

    @Test func missingOrOutOfWindowGeometryCannotProduceAClick() {
        let candidates: [CGRect?] = [nil, .zero, CGRect(x: 150, y: 150, width: 1, height: 20),
            CGRect(x: 99, y: 150, width: 100, height: 20), CGRect(x: 690, y: 150, width: 100, height: 20)]
        for bounds in candidates {
            #expect(FinderContextMenuTarget.point(displayedName: "Generated", windowBounds: window,
                fields: [.init(name: "Generated", bounds: bounds)]) == nil)
        }
    }
}
#endif
