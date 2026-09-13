#if os(macOS) && STABILITY
import CoreGraphics
import Foundation

enum FinderTransferCancellationTarget {
    struct Indicator {
        let fraction: Double?
        let bounds: CGRect?
    }

    /// Finder exposes its transfer ring as AXProgressIndicator, without an AX
    /// Cancel button. A native hit is allowed only on the one active indicator
    /// inside the independently bound row/window. The callback proves cancellation.
    static func point(window: CGRect, row: CGRect, indicators: [Indicator]) -> CGPoint? {
        guard window.contains(row), indicators.count == 1, let indicator = indicators.first,
              let fraction = indicator.fraction, fraction.isFinite, fraction > 0, fraction < 1,
              let bounds = indicator.bounds, bounds.width > 1, bounds.height > 1,
              row.contains(bounds) else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
#endif
