#if os(macOS) && STABILITY
/// Only transient root menus can originate the command on our bound selection.
/// Expanded submenus and application menu-bar commands are not competing roots.
enum FinderPopupMenuDiscovery {
    enum Role { case menu, menuBar, other }

    static func roots<Element>(from root: Element, limit: Int = 5_000,
                               role: (Element) -> Role, children: (Element) -> [Element],
                               visible: (Element) -> Bool) -> [Element] {
        var queue = [root], roots: [Element] = [], visited = 0
        while let element = queue.popLast() {
            guard visited < limit else { return [] }
            visited += 1
            switch role(element) {
            case .menu:
                if visible(element) { roots.append(element) }
                // Even a hidden submenu is subordinate to this root.
            case .menuBar: break
            case .other: queue += children(element)
            }
        }
        return roots
    }
}
#endif
