#if os(macOS) && STABILITY
import CoreGraphics
import Foundation

@MainActor
enum FinderPointerClick {
    /// Move first so WindowServer and hover controls see the same target as the
    /// subsequent click. Revalidate after that event; never inherit modifiers.
    static func perform(at point: CGPoint, button: CGMouseButton,
                        mayClick: () throws -> Bool,
                        canPostEvents: () -> Bool = { CGPreflightPostEventAccess() },
                        post: (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
                        settle: () async throws -> Void = { try await Task.sleep(for: .milliseconds(40)) }) async throws -> Bool {
        let permitted = canPostEvents()
        print("finder stability UI: native pointer permission=\(permitted)")
        guard permitted else { throw FinderUIError.permissionRequired }
        guard try mayClick() else { return false }
        post(try event(.mouseMoved, at: point, button: button))
        try await settle()
        let cursor = CGEvent(source: nil)?.location
        print("finder stability UI: session pointer position confirmed=\(cursor.map { abs($0.x - point.x) < 2 && abs($0.y - point.y) < 2 } == true)")
        guard try mayClick() else { return false }
        let down = try event(button == .right ? .rightMouseDown : .leftMouseDown, at: point, button: button)
        let up = try event(button == .right ? .rightMouseUp : .leftMouseUp, at: point, button: button)
        post(down)
        // Release even if the task is cancelled while the button is down.
        defer { post(up) }
        try await settle()
        return true
    }

    private static func event(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw FinderUIError.controlUnavailable
        }
        event.flags = []
        event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
        return event
    }
}
#endif
