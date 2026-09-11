#if os(macOS) && STABILITY
import Foundation

/// The Actions sheet can have its own AX process despite being hosted in Finder.
/// Neither a matching bundle identifier nor a window title alone binds the panel.
enum FinderActionPanelTarget {
    static func isExpectedProcess(executableURL: URL?, expectedURL: URL, codeHash: String?, expectedCodeHash: String?) -> Bool {
        guard let executableURL, let codeHash, let expectedCodeHash else { return false }
        return executableURL.standardizedFileURL.resolvingSymlinksInPath() == expectedURL.standardizedFileURL.resolvingSymlinksInPath()
            && codeHash == expectedCodeHash
    }

    /// FileProviderUI can omit a hosted sheet from AXWindows while exposing it
    /// as AXMainWindow. Discovery does not authorize it; the exact alias still must match.
    static func candidates<Element>(listed: [Element], main: Element?, equal: (Element, Element) -> Bool) -> [Element] {
        var result = listed
        if let main, !result.contains(where: { equal($0, main) }) { result.append(main) }
        return result
    }

    static func index(alias: String, windowIdentifiers: [[String]]) -> Int? {
        guard alias.hasPrefix("provider.stability.action."),
              UUID(uuidString: String(alias.dropFirst("provider.stability.action.".count))) != nil else { return nil }
        let matches = windowIdentifiers.indices.filter { windowIdentifiers[$0].contains(alias) }
        return matches.count == 1 ? matches.first : nil
    }
}
#endif
