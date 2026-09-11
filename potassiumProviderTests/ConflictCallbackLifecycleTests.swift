import FileProvider
import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing

struct ConflictCallbackLifecycleTests {
    @Test(.timeLimit(.minutes(1))) func gatePreservesReleaseAndCancellationOrdering() async throws {
        let earlyRelease = ConflictTestGate()
        await earlyRelease.release()
        try await earlyRelease.arrive()
        try await earlyRelease.waitUntilReached()
        let cancelled = ConflictTestGate()
        let worker = Task { try await cancelled.arrive() }
        defer { worker.cancel() }
        try await cancelled.waitUntilReached()
        worker.cancel()
        await cancelled.release()
        await #expect(throws: CancellationError.self) { try await worker.value }
    }

    @Test(arguments: [401, 403, 408, 429, 507])
    func productionErrorMappingIsRecoverableAndDoesNotLoseSafeStatus(status: Int) {
        let result = providerErrorMapping(APIClientError.unacceptableStatusCode(status, body: "synthetic"))
        let error = result.mappedError as NSError
        let expected: NSFileProviderError.Code = switch status {
        case 401: .notAuthenticated
        case 408, 429: .serverUnreachable
        case 507: .insufficientQuota
        default: .cannotSynchronize
        }
        #expect(error.domain == NSFileProviderErrorDomain && error.code == expected.rawValue)
    }

    @Test func failOnConflictAndOfflineMapThroughProductionMapper() {
        let item = ConflictTestRemote.item(3, name: "Synthetic.txt", parent: 1)
        let conflict = KDriveMutationConflictError.localContentConflict(latestItem: item,
            stagedURL: URL(filePath: "/synthetic/retained"))
        let mapped = providerErrorMapping(conflict).mappedError as NSError
        #expect(mapped.domain == NSFileProviderErrorDomain && mapped.code == NSFileProviderError.localVersionConflictingWithServer.rawValue)
        #expect((providerErrorMapping(URLError(.notConnectedToInternet)).mappedError as NSError).code == NSFileProviderError.serverUnreachable.rawValue)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingActualMutationSequencePreventsLateSuccessAndServerMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = try ConflictTestRemote(directory: directory.appendingPathComponent("server"))
        let client = ConflictTestClient(directory: directory.appendingPathComponent("client"), remote: remote)
        let base = try await remote.item(driveID: 7, fileID: 3)
        try client.cache(base)
        let gate = ConflictTestGate()
        await remote.gateReplacement(gate)
        let result = CallbackOutcomeRecorder()
        let progress = Progress(totalUnitCount: 100)
        let lifecycle = FileProviderOperationLifecycle(progress: progress) { result.record("cancelled") }
        let executor = KDriveModificationExecutor(coordinator: client.coordinator) { try await remote.item(driveID: 7, fileID: $0) }
        lifecycle.start { lifecycle in
            defer { result.finishWorker() }
            do {
                _ = try await executor.execute(fileID: 3, filename: base.name,
                    baseVersion: KDriveItemBaseVersion(contentVersion: base.contentVersion, metadataVersion: base.metadataVersion),
                    fields: [.contents, .parentItemIdentifier], destinationParentID: nil, requestsTrash: true,
                    modificationDate: nil, hasContents: true) { try await client.edit(Data("local".utf8)) }
                await lifecycle.finish(markProgressComplete: true) { result.record("success") }
            } catch is CancellationError { await lifecycle.cancel() }
            catch { await lifecycle.finish(markProgressComplete: false) { result.record("failure") } }
        }
        try await gate.waitUntilReached()
        await lifecycle.cancel()
        await gate.release()
        await lifecycle.finish(markProgressComplete: true) { result.record("late-success") }
        #expect(result.values == ["cancelled"])
        #expect(progress.completedUnitCount == 0)
        await result.waitForWorker()
        #expect(result.workerFinished)
        #expect(await remote.operations() == [])
        #expect(await remote.snapshot().trash.isEmpty)
        let staged = try FileManager.default.contentsOfDirectory(at: client.directory.appendingPathComponent("staging"), includingPropertiesForKeys: nil)
        #expect(try staged.map { try Data(contentsOf: $0) } == [Data("local".utf8)])
        #expect(try await remote.downloadFile(driveID: 7, fileID: 3) == Data("base".utf8))
    }
}

private final class CallbackOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [String] = []
    private var finished = false
    private let workerTerminal = AsyncStream<Void>.makeStream()
    func finishWorker() {
        lock.withLock { finished = true }
        workerTerminal.continuation.finish()
    }
    func waitForWorker() async { for await _ in workerTerminal.stream { } }
    var workerFinished: Bool { lock.withLock { finished } }
    func record(_ value: String) { lock.withLock { outcomes.append(value) } }
    var values: [String] { lock.withLock { outcomes } }
}
