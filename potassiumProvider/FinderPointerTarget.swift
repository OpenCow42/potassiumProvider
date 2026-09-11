#if os(macOS) && STABILITY
import ApplicationServices
import Foundation

enum FinderPointerTarget {
    /// Finder can be frontmost while a system window intercepts the pointer.
    /// Do not read another application's UI or post through an obstructed target.
    static func verify(at point: CGPoint, processIdentifier: pid_t, scope: AXUIElement) throws {
        try verify(processIdentifier: processIdentifier, scope: scope, hitTest: {
            var hit: AXUIElement?
            let result = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit)
            guard result == .success else { return nil }
            return hit
        }, owner: { element in
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }, parent: { element in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return value as! AXUIElement
        }, equal: { CFEqual($0, $1) })
    }

    static func verify<Element>(processIdentifier: pid_t, scope: Element,
                                hitTest: () -> Element?, owner: (Element) -> pid_t?,
                                parent: (Element) -> Element?, equal: (Element, Element) -> Bool) throws {
        guard var element = hitTest() else { throw FinderUIError.pointerTargetObstructed }
        for _ in 0..<32 {
            // Never traverse a different app, including permission-alert hosts.
            guard owner(element) == processIdentifier else { throw FinderUIError.pointerTargetObstructed }
            if equal(element, scope) { return }
            guard let next = parent(element) else { break }
            element = next
        }
        throw FinderUIError.pointerTargetObstructed
    }
}
#endif
