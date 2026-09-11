import Darwin
import FileProvider
import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing
@preconcurrency import SQLite

@Suite("Provider diagnostic spans")
struct ProviderDiagnosticSpanTests {
    @Test(arguments: [false, true])
    func mappedSQLiteFailuresRetainOnlySafeCodeAndCategory(extended: Bool) async throws {
        let sink = InMemoryDiagnosticSink(), canary = UUID().uuidString
        let code: Int32 = extended ? 517 : 5
        let original: SQLite.Result = extended ? .extendedError(message: canary, extendedCode: code, statement: nil) :
            .error(message: canary, code: code, statement: nil)
        let mapped = providerErrorMapping(original).mappedError
        let span = await ProviderDiagnosticSpan.start(source: .fileProviderExtension, operation: .currentSyncAnchor, recorder: sink)
        await span.fail(error: mapped)
        let events = await sink.snapshot()
        #expect(events.last?.errorClass == .storage)
        #expect(events.last?.errorCode == Int(code))
        #expect(!String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains(canary))
    }
    @Test func snapshotRaceClassificationOmitsPrivateIdentifiers() async throws {
        let sink = InMemoryDiagnosticSink()
        let span = await ProviderDiagnosticSpan.start(source: .fileProviderExtension, operation: .workingSetRefresh, recorder: sink)
        await span.fail(error: KDriveSnapshotStoreError.staleSnapshot(domainIdentifier: "private-domain-sentinel", containerIdentifier: "private-container-sentinel"))
        let events = await sink.snapshot()
        #expect(events.last?.errorClass == .concurrentSnapshot)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        #expect(!json.contains("private-domain-sentinel"))
        #expect(!json.contains("private-container-sentinel"))
    }
    @Test func startAndOnlyOneTerminalEventAreRecordedUnderRaces() async {
        let sink = InMemoryDiagnosticSink()
        let span = await ProviderDiagnosticSpan.start(
            source: .fileProviderExtension,
            operation: .modifyItem,
            fieldShape: [.contents, .filename],
            routeTemplate: .upload,
            optionShape: [.conditionalETag],
            recorder: sink
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    switch index % 3 {
                    case 0:
                        await span.complete(statusClass: .success)
                    case 1:
                        await span.fail(error: URLError(.timedOut))
                    default:
                        await span.cancel()
                    }
                }
            }
        }

        let events = await sink.snapshot()
        #expect(events.filter { $0.phase == .started }.count == 1)
        #expect(events.filter { [.completed, .failed, .cancelled].contains($0.phase) }.count == 1)
        #expect(Set(events.map(\.correlationID)) == [span.correlationID])
        #expect(Set(events.compactMap(\.spanID)) == [span.spanID])
    }

    @Test func recorderFailuresNeverChangeCallerFlow() async {
        let sink = InMemoryDiagnosticSink(alwaysThrows: true)
        let span = await ProviderDiagnosticSpan.start(
            source: .fileProviderExtension,
            operation: .fetchContents,
            recorder: sink
        )

        await span.progress(fractionCompleted: 0.5)
        await span.checkpoint(hasCursor: false, hasMore: true, hasAnchor: true)
        await span.fail(error: URLError(.networkConnectionLost))

        #expect(await sink.attemptCount() == 4)
    }

    @Test func nestedSpanInheritsTaskLocalCorrelation() async {
        let callback = await ProviderDiagnosticSpan.start(
            source: .fileProviderExtension,
            operation: .createItem
        )

        let nested = await callback.withCorrelation {
            await ProviderDiagnosticSpan.start(
                source: .fileProviderExtension,
                operation: .uploadFile,
                routeTemplate: .upload
            )
        }
        let unrelated = await ProviderDiagnosticSpan.start(
            source: .fileProviderExtension,
            operation: .uploadFile
        )

        #expect(nested.correlationID == callback.correlationID)
        #expect(unrelated.correlationID != callback.correlationID)
        #expect(nested.spanID != callback.spanID)
    }

    @Test func progressAndDurationAreBounded() async {
        let sink = InMemoryDiagnosticSink()
        let span = await ProviderDiagnosticSpan.start(
            source: .finderRunner,
            operation: .finderScenario,
            recorder: sink
        )

        await span.progress(fractionCompleted: -10)
        await span.progress(fractionCompleted: 0.01)
        await span.progress(fractionCompleted: 0.349)
        await span.progress(fractionCompleted: 0.399)
        await span.progress(fractionCompleted: 10)
        await span.progress(fractionCompleted: .infinity)
        await span.complete()

        let events = await sink.snapshot()
        let progress = events.filter { $0.phase == .progress }
        #expect(progress.map(\.progressPercentBucket) == [0, 30, 100, 0])
        #expect(events.compactMap(\.durationMilliseconds).allSatisfy {
            (0...ProviderDiagnosticSpan.maximumDurationMilliseconds).contains($0)
        })
    }

    @Test func errorClassificationUsesOnlyClosedCategories() async throws {
        #expect(ProviderDiagnosticErrorClassifier.classify(CancellationError()) == .cancellation)
        #expect(ProviderDiagnosticErrorClassifier.classify(URLError(.notConnectedToInternet)) == .network)
        #expect(ProviderDiagnosticErrorClassifier.classify(URLError(.userAuthenticationRequired)) == .authentication)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        ) == .storage)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            APIClientError.unacceptableStatusCode(429, body: "private-canary-429")
        ) == .network)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            APIClientError.unacceptableStatusCode(507, body: "private-canary-507")
        ) == .quota)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSFileProviderError(.notAuthenticated)
        ) == .authentication)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSFileProviderError(.serverUnreachable)
        ) == .network)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSFileProviderError(.insufficientQuota)
        ) == .quota)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSFileProviderError(.cannotSynchronize)
        ) == .synchronization)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSFileProviderError(.noSuchItem)
        ) == .notFound)
        #expect(ProviderDiagnosticErrorClassifier.classify(
            NSFileProviderError(.syncAnchorExpired)
        ) == .invalidCursor)

        let privateCanary = "private-canary-7F01D30C/opaque"
        let sink = InMemoryDiagnosticSink()
        let span = await ProviderDiagnosticSpan.start(
            source: .fileProviderExtension,
            operation: .deleteItem,
            fieldShape: [.filename],
            optionShape: [.stableFileID],
            recorder: sink
        )
        await span.fail(error: NSError(
            domain: privateCanary,
            code: 998,
            userInfo: [NSLocalizedDescriptionKey: privateCanary]
        ))

        let data = try JSONEncoder().encode(await sink.snapshot())
        let encoded = try #require(String(data: data, encoding: .utf8))
        #expect(encoded.contains(privateCanary) == false)
        #expect(encoded.contains("unknown"))
    }

    @Test func fileProviderFieldClassificationCoversEverySDKFieldAndTrash() {
        let allFields: NSFileProviderItemFields = [
            .contents,
            .filename,
            .parentItemIdentifier,
            .lastUsedDate,
            .tagData,
            .favoriteRank,
            .creationDate,
            .contentModificationDate,
            .fileSystemFlags,
            .extendedAttributes,
            .typeAndCreator,
        ]

        #expect(ProviderDiagnosticFieldClassifier.classify(allFields) == [
            .contents,
            .filename,
            .parent,
            .lastUsedDate,
            .tagData,
            .favoriteRank,
            .creationDate,
            .contentModificationDate,
            .fileSystemFlags,
            .extendedAttributes,
            .typeAndCreator,
        ])
        #expect(ProviderDiagnosticFieldClassifier.classify(
            .parentItemIdentifier,
            isTrashDestination: true
        ) == [.parent, .trash])
    }
}

private actor InMemoryDiagnosticSink: ProviderDiagnosticRecording {
    private let alwaysThrows: Bool
    private var events: [ProviderDiagnosticEvent] = []
    private var attempts = 0

    init(alwaysThrows: Bool = false) {
        self.alwaysThrows = alwaysThrows
    }

    func recordDiagnostic(_ event: ProviderDiagnosticEvent) throws {
        attempts += 1
        if alwaysThrows {
            throw InMemoryDiagnosticSinkError.unavailable
        }
        events.append(event)
    }

    func snapshot() -> [ProviderDiagnosticEvent] {
        events
    }

    func attemptCount() -> Int {
        attempts
    }
}

private enum InMemoryDiagnosticSinkError: Error {
    case unavailable
}
