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

    /// A remote view can be reached from both Finder's host window and the
    /// extension's AXMainWindow. Deduplicate the actual panel, not its hosts.
    /// Distinct panels bearing the same alias remain ambiguous. The first
    /// candidate must be the owned Finder host; a detached AXMainWindow can
    /// retain its alias after dismissal and cannot authorize a panel alone.
    static func windowIndex<Element>(alias: String, panels: [[Element]],
        identifier: (Element) -> String?, equal: (Element, Element) -> Bool) -> Int? {
        guard index(alias: alias, windowIdentifiers: [[alias]]) != nil,
              panels.first?.contains(where: { identifier($0) == alias }) == true else { return nil }
        var unique: [Element] = []
        var result: Int?
        for (index, roots) in panels.enumerated() {
            for root in roots where identifier(root) == alias {
                if !unique.contains(where: { equal($0, root) }) { unique.append(root) }
                result = index
            }
        }
        return unique.count == 1 ? result : nil
    }
}
#endif
