#if os(macOS) && STABILITY
/// A missing File Provider command can be cached in one Finder window. Permit
/// one replacement of that owned window, never a broader/destructive command.
struct FinderMenuWindowRefresh {
    private var used = false

    mutating func claim(command: String, matchingCommands: Int, elapsed: Duration) -> Bool {
        guard !used, matchingCommands == 0, elapsed >= .seconds(2), [
            "Download Now", "Remove Download", "Restore from kDrive Trash",
            "Add to kDrive Favorites", "Remove from kDrive Favorites", "Duplicate on kDrive",
            "Share kDrive Link…", "Version History…"
        ].contains(command) else { return false }
        used = true
        return true
    }
}
#endif
