#if os(macOS) && STABILITY
import CoreGraphics

enum FinderToolbarActionTarget {
    // Live Finder's toolbar omits provider commands and selected-item deletion.
    // Use it only for the two built-in download commands verified through it.
    static func supports(command: String) -> Bool {
        ["Remove Download", "Download Now"].contains(command)
    }

    struct Button {
        let description: String?
        let enabled: Bool
        let bounds: CGRect?
    }

    /// Candidates must come from the one toolbar of the bound Finder window.
    static func index(window: CGRect, toolbar: CGRect, buttons: [Button]) -> Int? {
        guard window.contains(toolbar) else { return nil }
        let matches = buttons.indices.filter { buttons[$0].description == "Action" }
        guard matches.count == 1, let index = matches.first, buttons[index].enabled,
              let bounds = buttons[index].bounds, bounds.width > 1, bounds.height > 1,
              toolbar.contains(bounds) else { return nil }
        return index
    }
}
#endif
