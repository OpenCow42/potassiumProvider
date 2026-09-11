import Foundation
import Testing
@testable import PotassiumProviderCore

struct KDriveTransferProgressTests {
    @Test(.timeLimit(.minutes(1)))
    func nestedTransferProgressIsRecordedBeforeCompletion() async throws {
        let events = AsyncStream<ProviderDiagnosticEvent>.makeStream()
        let sink = TransferProgressSink(continuation: events.continuation)
        let span = await ProviderDiagnosticSpan.start(source: .fileProviderExtension,
            operation: .downloadFile, recorder: sink)
        let parent = Progress(totalUnitCount: 100)
        let child = Progress(totalUnitCount: 1_000)
        parent.addChild(child, withPendingUnitCount: 100)
        child.completedUnitCount = 400
        #expect(parent.completedUnitCount == 0)
        let tracker = PotassiumKDriveService.trackProgress(parent, with: span)
        defer { tracker.cancel(); events.continuation.finish() }
        var iterator = events.stream.makeAsyncIterator()
        while let event = await iterator.next() {
            if event.phase == .progress {
                #expect(event.progressPercentBucket == 40)
                break
            }
        }
        try Task.checkCancellation()
        child.completedUnitCount = 900
        while let event = await iterator.next() {
            if event.phase == .progress {
                #expect(event.progressPercentBucket == 90)
                break
            }
        }
        try Task.checkCancellation()
        #expect(parent.completedUnitCount == 0)
        tracker.cancel()
        await tracker.value
        await span.cancel()
        child.completedUnitCount = 1_000
        await span.progress(fractionCompleted: parent.fractionCompleted)
        let recorded = await sink.events
        #expect(recorded.filter { $0.phase == .progress }.compactMap(\.progressPercentBucket) == [40, 90])
        #expect(recorded.filter { [.completed, .cancelled, .failed].contains($0.phase) }.map(\.phase) == [.cancelled])
    }
}

private actor TransferProgressSink: ProviderDiagnosticRecording {
    let continuation: AsyncStream<ProviderDiagnosticEvent>.Continuation
    private(set) var events: [ProviderDiagnosticEvent] = []
    init(continuation: AsyncStream<ProviderDiagnosticEvent>.Continuation) { self.continuation = continuation }
    func recordDiagnostic(_ event: ProviderDiagnosticEvent) async throws {
        events.append(event)
        continuation.yield(event)
    }
}
