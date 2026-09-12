#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

struct FinderMenuWindowRefreshTests {
    @Test func oneMissingCommandRefreshDoesNotBecomeAnUnboundedRetry() {
        var policy = FinderMenuWindowRefresh()
        let early = policy.claim(command: "Download Now", matchingCommands: 0, elapsed: .seconds(1))
        let first = policy.claim(command: "Download Now", matchingCommands: 0, elapsed: .seconds(2))
        let repeated = policy.claim(command: "Download Now", matchingCommands: 0, elapsed: .seconds(60))
        #expect(!early && first && !repeated)
    }

    @Test(arguments: ["Delete Immediately…", "Empty Trash", "Open", "Unknown"])
    func otherCommandsNeverReplaceTheWindow(_ command: String) {
        var policy = FinderMenuWindowRefresh()
        let claimed = policy.claim(command: command, matchingCommands: 0, elapsed: .seconds(60))
        #expect(!claimed)
    }

    @Test(arguments: [1, 2])
    func presentOrAmbiguousCommandsDoNotRefresh(_ count: Int) {
        var policy = FinderMenuWindowRefresh()
        let claimed = policy.claim(command: "Restore from kDrive Trash", matchingCommands: count, elapsed: .seconds(60))
        #expect(!claimed)
    }
}
#endif
