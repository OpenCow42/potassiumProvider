#if os(macOS) && STABILITY
import Testing
@testable import potassiumProvider

@MainActor
struct FinderMenuCommandSequenceTests {
    enum UnexpectedWait: Error { case transferCompletion }

    @Test func downloadReturnsAfterDispatchAndDismissalWithoutWaitingForTransferCompletion() async throws {
        var transitions: [String] = []
        try await FinderMenuCommandSequence.perform(command: "Download Now",
            press: { throw UnexpectedWait.transferCompletion }, click: { transitions.append("click") },
            waitForDismissal: { transitions.append("dismissed") },
            waitForResult: { throw UnexpectedWait.transferCompletion })
        #expect(transitions == ["click", "dismissed"])
    }

    @Test(arguments: ["Remove Download", "Delete Immediately…", "Share kDrive Link…", "Version History…"])
    func otherCommandsRetainResultObservation(_ command: String) async throws {
        var transitions: [String] = []
        try await FinderMenuCommandSequence.perform(command: command,
            press: { transitions.append("press") }, click: { Issue.record("Unexpected click dispatch") },
            waitForDismissal: { transitions.append("dismissed") }, waitForResult: { transitions.append("result") })
        #expect(transitions == ["press", "dismissed", "result"])
    }

    @Test func failedDispatchCannotBecomeAnObservedAction() async {
        await #expect(throws: UnexpectedWait.self) {
            try await FinderMenuCommandSequence.perform(command: "Download Now",
                press: { Issue.record("Unexpected AX dispatch") }, click: { throw UnexpectedWait.transferCompletion },
                waitForDismissal: { Issue.record("Nothing was dispatched") }, waitForResult: { Issue.record("Nothing was dispatched") })
        }
    }
}
#endif
