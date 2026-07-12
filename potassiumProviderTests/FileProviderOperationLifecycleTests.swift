import Foundation
import PotassiumProviderCore
import Testing

struct FileProviderOperationLifecycleTests {
    @Test func progressCancellationCompletesExactlyOnce() async {
        let recorder = CompletionRecorder()
        let progress = Progress(totalUnitCount: 10)
        let lifecycle = FileProviderOperationLifecycle(progress: progress) {
            recorder.record("cancelled")
        }

        lifecycle.start { lifecycle in
            do {
                try await Task.sleep(for: .seconds(30))
                lifecycle.finish(markProgressComplete: true) {
                    recorder.record("success")
                }
            } catch {
                lifecycle.cancel()
            }
        }

        progress.cancel()
        lifecycle.finish(markProgressComplete: true) {
            recorder.record("late-success")
        }

        #expect(recorder.values == ["cancelled"])
        #expect(progress.completedUnitCount == 0)
    }

    @Test func successfulFinishCompletesProgressAndIgnoresLaterCancellation() async {
        let recorder = CompletionRecorder()
        let progress = Progress(totalUnitCount: 25)
        let lifecycle = FileProviderOperationLifecycle(progress: progress) {
            recorder.record("cancelled")
        }

        lifecycle.finish(markProgressComplete: true) {
            recorder.record("success")
        }
        progress.cancel()
        lifecycle.finish(markProgressComplete: false) {
            recorder.record("late-failure")
        }

        #expect(recorder.values == ["success"])
        #expect(progress.completedUnitCount == 25)
    }

    @Test func transferOperationExposesLiveProgressAndForwardsCancellation() async throws {
        let progress = Progress(totalUnitCount: 100)
        let recorder = CompletionRecorder()
        let operation = KDriveTransferOperation(
            progress: progress,
            value: { Data("contents".utf8) },
            cancellation: { recorder.record("cancelled") }
        )

        #expect(operation.progress === progress)
        #expect(try await operation.value == Data("contents".utf8))

        operation.cancel()
        #expect(recorder.values == ["cancelled"])
    }
}

private final class CompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []

    var values: [String] {
        lock.withLock { storedValues }
    }

    func record(_ value: String) {
        lock.withLock {
            storedValues.append(value)
        }
    }
}
