#if os(macOS) && STABILITY
import AppKit

@MainActor
enum FinderRunnerPanel {
    /// The caller retains its run lease and recorder while the sheet is open.
    static func awaitResume(message: String) async -> Bool {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Finder Stability — run paused"
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "This run is still being monitored"
        alert.informativeText = message
        alert.addButton(withTitle: "Recheck and continue")
        alert.addButton(withTitle: "Stop run")
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: panel) { continuation.resume(returning: $0) }
        }
        panel.close()
        return response == .alertFirstButtonReturn
    }
}
#endif
