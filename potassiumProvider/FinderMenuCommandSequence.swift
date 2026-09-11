#if os(macOS) && STABILITY
@MainActor
enum FinderMenuCommandSequence {
    static func perform(command: String, press: () throws -> Void, click: () throws -> Void,
        waitForDismissal: () async throws -> Void, waitForResult: () async throws -> Void) async throws {
        if command == "Download Now" {
            // Dispatch the native click without awaiting the command's work.
            // Callback/progress evidence owns transfer completion; cancellation
            // must be able to run while the transfer is still active.
            try click()
            try await waitForDismissal()
        } else {
            try press()
            try await waitForDismissal()
            try await waitForResult()
        }
    }
}
#endif
