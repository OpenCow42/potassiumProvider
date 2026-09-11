import Foundation
import PotassiumProviderCore
import Testing

@Suite("Stability diagnostics")
struct StabilityDiagnosticsTests {
    @Test func compilationConditionSelectsTheExpectedRuntimeProfile() {
        #if STABILITY
        #expect(ProviderRuntimeProfile.current == .stability)
        #else
        #expect(ProviderRuntimeProfile.current == .standard)
        #endif
    }

    @Test func jsonlStoreReplaysSanitizedActivityAndConflictEvents() async throws {
        let (_, run, store) = try await makeRun()
        let secret = "PRIVATE_CANARY_7f01d30c_customer_name"

        try await store.recordActivity(KDriveProviderActivityEvent(
            domainIdentifier: "account-domain-42",
            driveID: 9001,
            kind: .modify,
            outcome: .failure,
            severity: .error,
            itemIdentifier: "remote-item-77",
            itemName: secret,
            itemPath: "/customer/private/file.txt",
            summary: "Failed \(secret)",
            diagnostic: KDriveProviderActivityErrorDiagnostic(
                errorCategory: .api,
                recoverySuggestion: secret,
                diagnosticSummary: secret
            ),
            correlationID: UUID().uuidString,
            networkOperation: "replaceFile",
            remoteRequestID: "private-request-id"
        ))
        try await store.saveConflict(KDriveConflictEvent(
            domainIdentifier: "account-domain-42",
            driveID: 9001,
            operation: .conflict,
            originalItemIdentifier: "remote-item-77",
            originalItemName: secret,
            originalItemPath: "/customer/private/file.txt",
            resolutionState: .blockedRetryable,
            automaticallyResolved: false,
            resolutionKind: .retainedStagedUploadAfterFailure,
            resolutionSummary: secret,
            stagedUploadRelativePath: "ConflictStaging/private-file"
        ))

        let rawData = try Data(contentsOf: run.eventsURL)
        let raw = try #require(String(data: rawData, encoding: .utf8))
        for privateValue in [
            secret, "account-domain-42", "9001", "remote-item-77",
            "/customer/private/file.txt", "private-request-id", "ConflictStaging/private-file",
        ] {
            #expect(raw.contains(privateValue) == false)
        }

        let activity = try await store.recentActivity(domainIdentifier: "account-domain-42", limit: 10)
        let conflicts = try await store.recentConflicts(domainIdentifier: "account-domain-42", limit: 10)
        #expect(activity.count == 1)
        #expect(activity.first?.itemIdentifier == nil)
        #expect(activity.first?.summary == "Modify failed.")
        #expect(conflicts.count == 1)
        #expect(conflicts.first?.originalItemName == nil)
    }

    @Test func jsonlStoreToleratesOnlyAnInterruptedTrailingRecord() async throws {
        let (_, run, store) = try await makeRun()
        try await store.recordActivity(activity(id: UUID(), occurredAt: Date(timeIntervalSince1970: 1)))

        let handle = try FileHandle(forWritingTo: run.eventsURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schemaVersion\":1".utf8))
        try handle.close()

        #expect(try await store.recentActivity(domainIdentifier: "domain", limit: 10).count == 1)
        try await store.recordActivity(activity(id: UUID(), occurredAt: Date(timeIntervalSince1970: 2)))
        #expect(try await store.recentActivity(domainIdentifier: "domain", limit: 10).count == 2)

        try Data("not-json\n".utf8).write(to: run.eventsURL, options: .atomic)
        await #expect(throws: ProviderDiagnosticStoreError.self) {
            _ = try await store.recentActivity(domainIdentifier: nil, limit: 10)
        }
    }

    @Test func independentStoresSerializeConcurrentAppends() async throws {
        let (_, run, first) = try await makeRun()
        let second = try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let store = index.isMultiple(of: 2) ? first : second
                    try await store.recordActivity(self.activity(
                        id: UUID(),
                        occurredAt: Date(timeIntervalSince1970: TimeInterval(index))
                    ))
                }
            }
            try await group.waitForAll()
        }

        #expect(try await first.recentActivity(domainIdentifier: "domain", limit: 200).count == 100)
    }

    @Test func runCoordinatorWritesImmutableManifestAndPrunesOnlyCompletedBundles() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let first = try await coordinator.startRun(buildRevision: "abc123")
        #expect(FileManager.default.fileExists(atPath: first.manifestURL.path))
        #expect(try await coordinator.activeRun()?.runID == first.runID)
        _ = try await coordinator.finishRun(
            runID: first.runID,
            summary: StabilityRunSummary(assertionCount: 2, failedAssertionCount: 0, checkpointCount: 1)
        )
        #expect(try await coordinator.activeRun() == nil)

        for index in 0..<4 {
            let run = try await coordinator.startRun(buildRevision: "revision-\(index)")
            _ = try await coordinator.finishRun(
                runID: run.runID,
                summary: StabilityRunSummary(assertionCount: index, failedAssertionCount: 0, checkpointCount: 0)
            )
        }
        let active = try await coordinator.startRun(buildRevision: "active")
        let removed = try await coordinator.pruneCompletedRuns(maximumRunCount: 2, maximumTotalBytes: .max)
        #expect(removed.count == 3)
        #expect(FileManager.default.fileExists(atPath: active.directoryURL.path))
    }

    @Test func inactiveRunLeaseRejectsAnActiveRunAndAllowsSafeResetWorkAfterFinish() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let run = try await coordinator.startRun(buildRevision: nil)

        await #expect(throws: ProviderDiagnosticStoreError.runAlreadyActive) {
            _ = try await coordinator.withInactiveRunLease { true }
        }

        _ = try await coordinator.finishRun(
            runID: run.runID,
            summary: StabilityRunSummary(
                assertionCount: 0,
                failedAssertionCount: 0,
                checkpointCount: 0
            )
        )
        #expect(try await coordinator.withInactiveRunLease { true })
    }

    @Test func inactiveRunLeaseBlocksAnIndependentRunStartUntilRelease() async throws {
        let root = try temporaryDirectory()
        let resetCoordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let runCoordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let leaseGate = StabilityLeaseTestGate()
        let startState = StabilityRunStartTestState()

        let leaseTask = Task {
            try await resetCoordinator.withInactiveRunLease {
                await leaseGate.hold()
                return true
            }
        }
        await leaseGate.waitUntilHeld()

        let startTask = Task {
            await startState.markAttempted()
            let run = try await runCoordinator.startRun(buildRevision: "after-reset")
            await startState.markCompleted()
            return run
        }
        await startState.waitUntilAttempted()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(await startState.isCompleted == false)

        await leaseGate.release()
        #expect(try await leaseTask.value)
        let run = try await startTask.value
        #expect(await startState.isCompleted)
        #expect(try await runCoordinator.activeRun()?.runID == run.runID)
    }

    @Test func independentCoordinatorsSelectOneRunAndByteRetentionKeepsIncompleteRuns() async throws {
        let root = try temporaryDirectory()
        let first = StabilityRunCoordinator(rootDirectoryURL: root)
        let second = StabilityRunCoordinator(rootDirectoryURL: root)
        async let firstRun = first.startRun(buildRevision: "first")
        async let secondRun = second.startRun(buildRevision: "second")
        let selectedRuns = try await [firstRun, secondRun]
        #expect(Set(selectedRuns.map(\.runID)).count == 1)

        let active = try #require(selectedRuns.first)
        _ = try await first.finishRun(
            runID: active.runID,
            summary: StabilityRunSummary(assertionCount: 0, failedAssertionCount: 0, checkpointCount: 0)
        )
        let incomplete = try await second.startRun(buildRevision: "incomplete")
        let removed = try await first.pruneCompletedRuns(maximumRunCount: 20, maximumTotalBytes: 0)
        #expect(removed == [active.runID])
        #expect(FileManager.default.fileExists(atPath: incomplete.directoryURL.path))
    }

    @Test func diagnosticEventEncodingHasNoFreeFormPrivateFields() throws {
        let event = ProviderDiagnosticEvent(
            correlationID: UUID(),
            source: .fileProviderExtension,
            operation: .modifyItem,
            phase: .completed,
            fieldShape: [.contents, .filename, .parent],
            routeTemplate: .upload,
            optionShape: [.conditionalETag, .stableFileID, .clientToken, .contentHash],
            statusClass: .success,
            durationMilliseconds: 42,
            progressPercentBucket: 100,
            hasCursor: true,
            hasMore: false,
            hasAnchor: true
        )
        let data = try JSONEncoder().encode(event)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("modifyItem"))
        #expect(text.contains("authorization") == false)
        #expect(text.contains("url") == false)
    }

    @Test func factoryChangesOnlyTheEventStoreForAStartedStabilityRun() async throws {
        let root = try temporaryDirectory()
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: root)
        let run = try await coordinator.startRun(buildRevision: nil)
        let standardDatabaseURL = root.appendingPathComponent("Snapshots.sqlite3")

        let standardCandidate = try ProviderEventStoreFactory.make(
            profile: .standard,
            standardDatabaseURL: standardDatabaseURL,
            stabilityRootDirectoryURL: root
        )
        let stabilityCandidate = try ProviderEventStoreFactory.make(
            profile: .stability,
            standardDatabaseURL: standardDatabaseURL,
            stabilityRootDirectoryURL: root
        )
        let standard = try #require(standardCandidate)
        let stability = try #require(stabilityCandidate)

        #expect(standard is KDriveProviderEventSQLiteStore)
        #expect(stability is KDriveProviderEventJSONLStore)
        #expect(FileManager.default.fileExists(atPath: run.eventsURL.path))
        #expect(FileManager.default.fileExists(atPath: standardDatabaseURL.path))
    }

    @Test func jsonlProtocolsPreserveClearStatisticsPagingAndExportSemantics() async throws {
        let (_, _, store) = try await makeRun()
        try await store.recordActivity(activity(id: UUID(), occurredAt: Date(timeIntervalSince1970: 1)))
        try await store.recordActivity(KDriveProviderActivityEvent(
            occurredAt: Date(timeIntervalSince1970: 2),
            domainIdentifier: "domain",
            driveID: 1,
            kind: .modify,
            outcome: .failure,
            severity: .error,
            itemIdentifier: "PRIVATE_ITEM_CANARY",
            itemName: nil,
            itemPath: nil,
            summary: "PRIVATE_SUMMARY_CANARY"
        ))
        try await store.saveConflict(conflict(state: .unresolved, date: 3))
        try await store.saveConflict(conflict(state: .automaticallyResolved, date: 4))

        let statisticCandidates = try await store.eventStatistics(domainIdentifiers: ["domain"])
        let statistics = try #require(statisticCandidates.first)
        #expect(statistics.unresolvedConflictCount == 1)
        #expect(statistics.resolvedConflictCount == 1)
        #expect(statistics.recentSuccessCount == 1)
        #expect(statistics.recentFailureCount == 1)
        let page = try await store.timelinePage(filter: .errorsAndConflicts, before: nil, limit: 2)
        #expect(page.entries.count == 2)
        #expect(page.hasMore)
        let emptyPage = try await store.timelinePage(filter: .allActivity, before: nil, limit: 0)
        #expect(emptyPage.entries.isEmpty)
        #expect(emptyPage.hasMore == false)

        let export = try await store.supportLogData(domainIdentifier: "domain")
        let exportText = try #require(String(data: export, encoding: .utf8))
        #expect(exportText.contains("PRIVATE_ITEM_CANARY") == false)
        #expect(exportText.contains("PRIVATE_SUMMARY_CANARY") == false)

        try await store.removeActivityAndResolvedConflicts(domainIdentifier: "domain")
        #expect(try await store.recentActivity(domainIdentifier: "domain", limit: 10).isEmpty)
        let remaining = try await store.recentConflicts(domainIdentifier: "domain", limit: 10)
        #expect(remaining.count == 1)
        #expect(remaining.first?.resolutionState == .unresolved)
        try await store.removeEvents(domainIdentifier: "domain")
        #expect(try await store.recentConflicts(domainIdentifier: "domain", limit: 10).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func eventObservationSeesAnAppendFromAnotherStore() async throws {
        let (_, run, store) = try await makeRun()
        let writer = try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL)
        let changes = await store.eventChanges(pollInterval: 0.02)
        // No startup sleep: a returned subscription must already cover writes.
        try await writer.recordActivity(activity(id: UUID(), occurredAt: Date()))
        var iterator = changes.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func eventCapacityRejectsBeforeCorruptingReplayableEvidence() async throws {
        let (_, run, _) = try await makeRun()
        let store = try KDriveProviderEventJSONLStore(
            runDirectoryURL: run.directoryURL,
            maximumEventBytes: 700
        )
        try await store.recordActivity(activity(id: UUID(), occurredAt: Date()))
        await #expect(throws: ProviderDiagnosticStoreError.self) {
            for _ in 0..<20 {
                try await store.recordActivity(self.activity(id: UUID(), occurredAt: Date()))
            }
        }
        #expect(try await store.recentActivity(domainIdentifier: "domain", limit: 100).isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: run.directoryURL.appendingPathComponent("diagnostic-health.failed").path))
    }

    #if os(macOS)
    @Test func parentAndSubprocessWritersProduceOnlyCompleteRecords() async throws {
        let (_, run, store) = try await makeRun()
        for _ in 0..<50 {
            try await store.recordActivity(activity(id: UUID(), occurredAt: Date()))
        }
        let template = try Data(contentsOf: run.eventsURL)
        let templateURL = try temporaryDirectory().appendingPathComponent("sanitized-template.jsonl")
        try template.write(to: templateURL)
        let eventHandle = try FileHandle(forWritingTo: run.eventsURL)
        try eventHandle.truncate(atOffset: 0)
        try eventHandle.close()

        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(
            fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
        )
        process.arguments = [
            "-c",
            "import fcntl,os,sys,time; lines=open(sys.argv[2],'rb').readlines(); f=open(sys.argv[1],'ab',buffering=0); sys.stdout.write('1'); sys.stdout.flush(); [(fcntl.flock(f,fcntl.LOCK_EX),f.write(line),f.flush(),os.fsync(f.fileno()),fcntl.flock(f,fcntl.LOCK_UN),time.sleep(0.001)) for line in lines]",
            run.eventsURL.path,
            templateURL.path,
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let readyData = try output.fileHandleForReading.read(upToCount: 1)
        guard let ready = readyData else {
            process.waitUntilExit()
            let errorData = try errors.fileHandleForReading.readToEnd() ?? Data()
            Issue.record("Subprocess writer exited before ready (status \(process.terminationStatus)): \(String(decoding: errorData, as: UTF8.self))")
            return
        }
        #expect(ready == Data("1".utf8))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    try await store.recordActivity(self.activity(id: UUID(), occurredAt: Date()))
                }
            }
            try await group.waitForAll()
        }
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try await store.recentActivity(domainIdentifier: "domain", limit: 200).count == 100)
    }
    #endif

    @Test func completedRunRejectsCachedWriterAndSymlinkedEventFile() async throws {
        let (coordinator, run, store) = try await makeRun()
        _ = try await coordinator.finishRun(
            runID: run.runID,
            summary: StabilityRunSummary(assertionCount: 0, failedAssertionCount: 0, checkpointCount: 0)
        )
        await #expect(throws: ProviderDiagnosticStoreError.self) {
            try await store.recordActivity(self.activity(id: UUID(), occurredAt: Date()))
        }

        let (_, unsafeRun, _) = try await makeRun()
        try FileManager.default.removeItem(at: unsafeRun.eventsURL)
        let outside = try temporaryDirectory().appendingPathComponent("outside.jsonl")
        _ = FileManager.default.createFile(atPath: outside.path, contents: nil)
        try FileManager.default.createSymbolicLink(at: unsafeRun.eventsURL, withDestinationURL: outside)
        #expect(throws: ProviderDiagnosticStoreError.self) {
            _ = try KDriveProviderEventJSONLStore(runDirectoryURL: unsafeRun.directoryURL)
        }
    }

    private func activity(id: UUID, occurredAt: Date) -> KDriveProviderActivityEvent {
        KDriveProviderActivityEvent(
            id: id,
            occurredAt: occurredAt,
            domainIdentifier: "domain",
            driveID: 1,
            kind: .enumeration,
            itemIdentifier: nil,
            itemName: nil,
            itemPath: nil,
            summary: "Enumerated."
        )
    }

    private func conflict(state: KDriveConflictResolutionState, date: TimeInterval) -> KDriveConflictEvent {
        KDriveConflictEvent(
            detectedAt: Date(timeIntervalSince1970: date),
            domainIdentifier: "domain",
            driveID: 1,
            operation: .conflict,
            originalItemIdentifier: nil,
            originalItemName: nil,
            originalItemPath: nil,
            resolutionState: state,
            automaticallyResolved: state == .automaticallyResolved,
            resolutionKind: nil,
            resolutionSummary: "PRIVATE_CONFLICT_CANARY"
        )
    }

    private func makeRun() async throws -> (
        StabilityRunCoordinator,
        StabilityRunHandle,
        KDriveProviderEventJSONLStore
    ) {
        let coordinator = StabilityRunCoordinator(rootDirectoryURL: try temporaryDirectory())
        let run = try await coordinator.startRun(buildRevision: nil)
        return (coordinator, run, try KDriveProviderEventJSONLStore(runDirectoryURL: run.directoryURL))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StabilityDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private actor StabilityLeaseTestGate {
    private var isHeld = false
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        heldWaiters.forEach { $0.resume() }
        heldWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilHeld() async {
        guard isHeld == false else { return }
        await withCheckedContinuation { continuation in
            heldWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor StabilityRunStartTestState {
    private var attempted = false
    private var completed = false
    private var attemptedWaiters: [CheckedContinuation<Void, Never>] = []

    var isCompleted: Bool { completed }

    func markAttempted() {
        attempted = true
        attemptedWaiters.forEach { $0.resume() }
        attemptedWaiters.removeAll()
    }

    func waitUntilAttempted() async {
        guard attempted == false else { return }
        await withCheckedContinuation { continuation in
            attemptedWaiters.append(continuation)
        }
    }

    func markCompleted() {
        completed = true
    }
}
