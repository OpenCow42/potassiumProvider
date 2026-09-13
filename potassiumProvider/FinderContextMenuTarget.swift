#if os(macOS) && STABILITY
import Foundation
import CoreGraphics

enum FinderContextMenuTarget {
    struct Field {
        let name: String?
        let bounds: CGRect?
    }

    /// Fields must come only from the independently verified selected row.
    /// Advertised AX actions do not govern WindowServer secondary-click routing.
    static func point(displayedName: String, windowBounds: CGRect, fields: [Field]) -> CGPoint? {
        guard !displayedName.isEmpty else { return nil }
        let matches = fields.filter { $0.name == displayedName }
        guard matches.count == 1, let bounds = matches.first?.bounds,
              bounds.width > 1, bounds.height > 1, windowBounds.contains(bounds) else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
#endif
