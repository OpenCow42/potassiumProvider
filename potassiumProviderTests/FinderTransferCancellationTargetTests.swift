#if os(macOS) && STABILITY
import CoreGraphics
import Foundation
import Testing
@testable import potassiumProvider

struct FinderTransferCancellationTargetTests {
    let window = CGRect(x: 100, y: 100, width: 600, height: 400)
    let row = CGRect(x: 300, y: 180, width: 350, height: 24)
    let ring = CGRect(x: 500, y: 182, width: 20, height: 20)

    @Test func onlyTheActiveIndicatorInTheBoundRowCanBeClicked() {
        #expect(FinderTransferCancellationTarget.point(window: window, row: row,
            indicators: [.init(fraction: 0.4, bounds: ring)]) == CGPoint(x: 510, y: 192))
        #expect(FinderTransferCancellationTarget.point(window: window, row: row, indicators: []) == nil)
        #expect(FinderTransferCancellationTarget.point(window: window, row: row,
            indicators: [.init(fraction: 0.4, bounds: ring), .init(fraction: 0.5, bounds: ring)]) == nil)
    }

    @Test(arguments: [nil, 0, 1, -1, 2, .nan, .infinity] as [Double?])
    func missingOrTerminalProgressNeverBecomesACancelTarget(fraction: Double?) {
        #expect(FinderTransferCancellationTarget.point(window: window, row: row,
            indicators: [.init(fraction: fraction, bounds: ring)]) == nil)
    }

    @Test func missingOrUnconfinedGeometryNeverBecomesACancelTarget() {
        for bounds in [nil, .zero, CGRect(x: 500, y: 205, width: 20, height: 20)] as [CGRect?] {
            #expect(FinderTransferCancellationTarget.point(window: window, row: row,
                indicators: [.init(fraction: 0.4, bounds: bounds)]) == nil)
        }
        #expect(FinderTransferCancellationTarget.point(window: .zero, row: row,
            indicators: [.init(fraction: 0.4, bounds: ring)]) == nil)
    }
}
#endif
