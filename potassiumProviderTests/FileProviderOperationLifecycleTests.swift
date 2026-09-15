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
                await lifecycle.finish(markProgressComplete: true) {
                    recorder.record("success")
                }
            } catch {
                await lifecycle.cancel()
            }
        }

        progress.cancel()
        await lifecycle.finish(markProgressComplete: true) {
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

        await lifecycle.finish(markProgressComplete: true) {
            recorder.record("success")
        }
        progress.cancel()
        await lifecycle.finish(markProgressComplete: false) {
            recorder.record("late-failure")
        }

        #expect(recorder.values == ["success"])
        #expect(progress.completedUnitCount == 25)
    }

    @Test func cancellationBeforeStartDoesNotLaunchOperation() async {
        let recorder = CompletionRecorder()
        let progress = Progress(totalUnitCount: 1)
        let lifecycle = FileProviderOperationLifecycle(progress: progress) {
            recorder.record("cancelled")
        }

        progress.cancel()
        lifecycle.start { _ in
            recorder.record("started")
        }
        await lifecycle.finish(markProgressComplete: true) {
            recorder.record("late-success")
        }

        #expect(recorder.values == ["cancelled"])
        #expect(progress.completedUnitCount == 0)
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

    @Test func diagnosticLifecycleRecordsOneTerminalOutcome() async throws {
        let sink = LifecycleDiagnosticSink()
        let progress = Progress(totalUnitCount: 1)
        let lifecycle = FileProviderOperationLifecycle(
            progress: progress,
            diagnosticOperation: .modifyItem,
            diagnosticFieldShape: [.contents, .filename],
            diagnosticRecorder: sink
        ) {}

        let privateFailure = NSError(
            domain: "private-canary-9C42",
            code: 91
        )
        await lifecycle.finish(
            markProgressComplete: false,
            diagnosticError: privateFailure
        ) {}
        await lifecycle.cancel()

        let events = try await sink.waitForEvents(count: 2)
        #expect(events.map(\.phase) == [.started, .failed])
        #expect(Set(events.map(\.correlationID)).count == 1)
        #expect(events.last?.errorClass == .unknown)
        #expect(events.last?.fieldShape == [.contents, .filename])
    }

    @Test func successfulCallbackRecordsReturnedMetadataOnce() async throws {
        let sink = LifecycleDiagnosticSink()
        let lifecycle = FileProviderOperationLifecycle(progress: Progress(totalUnitCount: 1),
            diagnosticOperation: .modifyItem, diagnosticRecorder: sink) {}
        let alias = UUID()
        await lifecycle.finish(markProgressComplete: true, diagnosticItemMetadataAlias: alias) {}
        await lifecycle.finish(markProgressComplete: true, diagnosticItemMetadataAlias: UUID()) {}
        let events = try await sink.waitForEvents(count: 2)
        #expect(events.map(\.phase) == [.started, .completed])
        #expect(events.first?.itemMetadataAlias == nil)
        #expect(events.last?.itemMetadataAlias == alias)
    }

    @Test func cancellationWhileDiagnosticStartIsSuspendedNeverLaunchesWork() async {
        let completion = CompletionRecorder()
        let sink = SuspendingLifecycleDiagnosticSink()
        let lifecycle = FileProviderOperationLifecycle(
            progress: Progress(totalUnitCount: 1),
            diagnosticOperation: .deleteItem,
            diagnosticRecorder: sink
        ) {
            completion.record("cancelled")
        }

        lifecycle.start { _ in
            completion.record("operation-started")
        }
        await sink.waitUntilEntered()
        let cancellation = Task {
            await lifecycle.cancel()
        }
        await Task.yield()
        await sink.release()
        await cancellation.value
        for _ in 0..<100 {
            await Task.yield()
        }

        #expect(completion.values == ["cancelled"])
    }
}

private actor LifecycleDiagnosticSink: ProviderDiagnosticRecording {
    private var events: [ProviderDiagnosticEvent] = []

    func recordDiagnostic(_ event: ProviderDiagnosticEvent) {
        events.append(event)
    }

    func waitForEvents(count: Int) async throws -> [ProviderDiagnosticEvent] {
        for _ in 0..<200 where events.count < count {
            await Task.yield()
        }
        guard events.count >= count else {
            throw LifecycleDiagnosticSinkError.timedOut
        }
        return events
    }
}

private enum LifecycleDiagnosticSinkError: Error {
    case timedOut
}

private actor SuspendingLifecycleDiagnosticSink: ProviderDiagnosticRecording {
    private var isBlocked = true
    private var hasEntered = false

    func recordDiagnostic(_ event: ProviderDiagnosticEvent) async {
        hasEntered = true
        while isBlocked {
            await Task.yield()
        }
    }

    func waitUntilEntered() async {
        while hasEntered == false {
            await Task.yield()
        }
    }

    func release() {
        isBlocked = false
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
