#if os(macOS) && STABILITY
import AppKit
import FileProvider
import PotassiumProviderCore

@MainActor
final class FinderLiveRunSession {
    let context: FinderStabilityLiveContext
    let run: StabilityRunHandle
    let ui: any FinderUIDriving
    let expectedExtensionCodeHash: String
    let expectedActionsCodeHash: String
    var root: KDriveRemoteItem?
    var nested: KDriveRemoteItem?
    var deep: KDriveRemoteItem?
    var sibling: KDriveRemoteItem?
    var seed: KDriveRemoteItem?
    var file: KDriveRemoteItem?
    var directory: KDriveRemoteItem?
    var transfer: KDriveRemoteItem?
    var bytes = Data("stability file version one\n".utf8)
    var owned: [Int: KDriveRemoteItem] = [:]
    var subjects: Set<UUID> = []
    var correlationID = UUID()
    var conflictReached = false
    var cancellationObserved = false
    var workingSetMember = false
    var expectedWorkingSetMetadataAlias: UUID?
    var lastVisibleURL: URL?
    var deadline = StabilityDeadline(budget: .seconds(90))

    init(context: FinderStabilityLiveContext, ui: any FinderUIDriving) throws {
        self.context = context
        self.ui = ui
        guard let run = try StabilityDiagnosticIdentity.activeRun() else { throw FinderLiveError.missingRun }
        self.run = run
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/potassiumProviderFileProvider.appex")
        guard let hash = StabilityDiagnosticIdentity.codeHash(at: extensionURL) else { throw FinderLiveError.unverifiedBuild }
        self.expectedExtensionCodeHash = hash
        guard let actionsHash = StabilityDiagnosticIdentity.codeHash(at: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/potassiumProviderActions.appex")) else {
            throw FinderLiveError.unverifiedBuild
        }
        self.expectedActionsCodeHash = actionsHash
    }

    func remember(_ item: KDriveRemoteItem) {
        owned[item.id] = item
        subject(String(item.id))
    }
    func subject(_ identifier: String) { subjects.insert(StabilityDiagnosticIdentity.alias(for: identifier, runID: run.runID)) }
    func require<T>(_ value: T?) throws -> T { guard let value else { throw FinderLiveError.missingFixture }; return value }

    func setup() async throws {
        try await context.verifySafety()
        try await ui.navigate(to: context.rootURL)
        try await signal(.rootContainer)
        let rootSubject = StabilityDiagnosticIdentity.alias(for: NSFileProviderItemIdentifier.rootContainer.rawValue, runID: run.runID)
        try await poll {
            let callbacks = try self.diagnostics().filter { $0.source == .fileProviderExtension && $0.subjectAlias == rootSubject }
            guard callbacks.allSatisfy({ $0.processCodeHash == self.expectedExtensionCodeHash && $0.processInstanceID != nil }) else {
                throw FinderLiveError.unverifiedBuild
            }
            return callbacks.contains { $0.phase == .completed }
        }
        let name = "stability-run-" + run.runID.uuidString.lowercased()
        let item = try await context.remote.createDirectory(driveID: context.domain.driveID, parentID: context.domain.rootFileID, name: name)
        guard item.parentID == context.domain.rootFileID, item.id != context.domain.rootFileID, item.isDirectory else { throw FinderLiveError.unsafeTarget }
        root = item; remember(item)
        nested = try await createDirectory(name: "Nested", parent: item)
        deep = try await createDirectory(name: "Deep", parent: try require(nested))
        sibling = try await createDirectory(name: "Sibling", parent: item)
        seed = try await upload(name: "remote-seed.txt", parent: try require(deep), data: bytes)
        try await signal(.rootContainer)
    }

    func createDirectory(name: String, parent: KDriveRemoteItem) async throws -> KDriveRemoteItem {
        try await verifyOwned(parent)
        let item = try await context.remote.createDirectory(driveID: context.domain.driveID, parentID: parent.id, name: name)
        guard item.parentID == parent.id, item.isDirectory else { throw FinderLiveError.unsafeTarget }
        remember(item)
        return item
    }

    func upload(name: String, parent: KDriveRemoteItem, data: Data) async throws -> KDriveRemoteItem {
        try await verifyOwned(parent)
        let item = try await context.remote.uploadFile(driveID: context.domain.driveID, parentID: parent.id, fileName: name,
            contents: data, lastModifiedAt: Date(), conflictStrategy: .error,
            clientToken: KDriveMutationIdentity.clientToken([run.runID.uuidString, name]), contentHash: KDriveMutationIdentity.contentHash(data))
        guard item.parentID == parent.id, !item.isDirectory else { throw FinderLiveError.unsafeTarget }
        remember(item)
        return item
    }

    func verifyOwned(_ item: KDriveRemoteItem) async throws {
        guard owned[item.id] != nil, let root else { throw FinderLiveError.unsafeTarget }
        try await context.verifySafety()
        let remote = context.remote, driveID = context.domain.driveID
        try await StabilityRunConfinement.verify(targetID: item.id, runRootID: root.id, labRootID: context.domain.rootFileID,
            driveID: driveID, ownedIDs: Set(owned.keys)) { identifier in
                try await remote.item(driveID: driveID, fileID: identifier)
            }
    }

    func visible(_ item: KDriveRemoteItem, trashed: Bool = false) async throws -> URL {
        guard owned[item.id] != nil else { throw FinderLiveError.unsafeTarget }
        let manager = context.fileProviderManager
        let url = try await StabilityCallbackWaiter<URL>().wait(timeout: deadline.remaining()) { completion in
            manager.getUserVisibleURL(for: NSFileProviderItemIdentifier(String(item.id))) { url, error in
                if let error { completion(.failure(error)) }
                else if let url { completion(.success(url)) }
                else { completion(.failure(FinderLiveError.missingFixture)) }
            }
        }
        try await bind(url, item: item, trashed: trashed)
        return url
    }

    func bind(_ url: URL, item: KDriveRemoteItem, trashed: Bool = false) async throws {
        guard owned[item.id] != nil else { throw FinderLiveError.unsafeTarget }
        if trashed {
            try await context.verifySafety()
            guard let actions = context.remote as? any KDriveContextActionProviding else { throw FinderLiveError.missingCapability }
            let remote = try await actions.trashedItem(driveID: context.domain.driveID, fileID: item.id)
            guard remote.id == item.id, remote.driveID == context.domain.driveID, owned[item.parentID] != nil else { throw FinderLiveError.unsafeTarget }
        } else { try await verifyOwned(item) }
        let binding = try await StabilityCallbackWaiter<(String, String)>().wait(timeout: deadline.remaining()) { completion in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) { identifier, domain, error in
                if let error { completion(.failure(error)) }
                else if let identifier, let domain { completion(.success((identifier.rawValue, domain.rawValue))) }
                else { completion(.failure(FinderLiveError.unsafeTarget)) }
            }
        }
        guard FinderStabilityTargetBinding.matches(expectedFileID: item.id, expectedDomainIdentifier: context.domain.domainIdentifier,
            actualItemIdentifier: binding.0, actualDomainIdentifier: binding.1) else { throw FinderLiveError.unsafeTarget }
        subject(String(item.id)); subject(String(item.parentID))
        ui.expectActionPanel(for: StabilityDiagnosticIdentity.alias(for: String(item.id), runID: run.runID))
        lastVisibleURL = url
    }

    func list(_ parent: KDriveRemoteItem) async throws -> [KDriveRemoteItem] {
        var cursor: String?, seen: Set<String> = [], items: [KDriveRemoteItem] = []
        for _ in 0..<100 {
            let page = try await context.remote.listDirectory(driveID: context.domain.driveID, folderID: parent.id, cursor: cursor, limit: 200)
            guard page.items.allSatisfy({ $0.parentID == parent.id }) else { throw FinderLiveError.unsafeTarget }
            items += page.items
            guard page.hasMore else { return items }
            guard let next = page.nextCursor, seen.insert(next).inserted, !page.items.isEmpty else { throw FinderLiveError.invalidPagination }
            cursor = next
        }
        throw FinderLiveError.invalidPagination
    }

    func waitItem(named name: String, parent: KDriveRemoteItem) async throws -> KDriveRemoteItem {
        var result: KDriveRemoteItem?
        try await poll { result = try await self.list(parent).first { $0.name == name }; return result != nil }
        let item = try require(result)
        remember(item)
        return item
    }

    func waitMetadata(_ item: KDriveRemoteItem, predicate: @escaping (KDriveRemoteItem) -> Bool) async throws -> KDriveRemoteItem {
        var result: KDriveRemoteItem?
        try await poll {
            let value = try await self.context.remote.item(driveID: self.context.domain.driveID, fileID: item.id)
            if predicate(value) { result = value; return true }
            return false
        }
        let resolved = try require(result)
        remember(resolved)
        return resolved
    }

    func waitBytes(_ item: KDriveRemoteItem, expected: Data) async throws {
        try await poll {
            try await self.context.remote.downloadFile(driveID: self.context.domain.driveID, fileID: item.id) == expected
        }
    }

    func diagnostics() throws -> [ProviderDiagnosticEvent] { try StabilityRunCoordinator.readDiagnosticEvents(from: run.eventsURL) }

    /// A controlled diagnostic comparison after a failed navigation run. This
    /// writes the unchanged timestamp of the untouched generated seed file;
    /// its separate correlation can never satisfy a Finder scenario assertion.
    func diagnoseDirectoryDateRejection() async {
        guard let seed, let events = try? diagnostics() else { return }
        let directoryAliases = Set(owned.values.filter(\.isDirectory).map {
            StabilityDiagnosticIdentity.alias(for: String($0.id), runID: run.runID)
        })
        guard events.contains(where: { $0.operation == .updateModificationDate && $0.phase == .failed &&
            $0.errorCode == 400 && $0.subjectAlias.map(directoryAliases.contains) == true }) else { return }
        do {
            try await ProviderDiagnosticCorrelationContext.withCorrelation(UUID()) { @MainActor in
                try await self.verifyOwned(seed)
                try await ProviderDiagnosticCorrelationContext.$subjectAlias.withValue(
                    StabilityDiagnosticIdentity.alias(for: String(seed.id), runID: self.run.runID)) {
                    try await self.context.remote.updateModificationDate(driveID: self.context.domain.driveID,
                        fileID: seed.id, date: seed.modifiedAt)
                }
            }
            print("finder stability diagnostic probe: unchanged file timestamp accepted; directory timestamp rejected")
        } catch {
            print("finder stability diagnostic probe: unchanged file timestamp rejected; class \(ProviderDiagnosticErrorClassifier.classify(error).rawValue); status \(KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode ?? 0)")
        }
    }

    func awaitDiagnostics(scenario: StabilityFinderScenario, startedAt: Date, actions: Int) async throws -> StabilityLiveStepEvidence {
        let proof = evidence(actions: actions)
        try await poll {
            let result = StabilityFinderStepResult(sequenceNumber: 1, scenario: scenario, correlationID: self.correlationID,
                startedAt: startedAt, finishedAt: Date(), outcome: .passed, assertions: [], liveEvidence: proof)
            do { try StabilityLiveEvidenceValidator.validate(step: result, diagnostics: self.diagnostics()); return true }
            catch StabilityLiveEvidenceError.wrongExtensionBuild { throw FinderLiveError.unverifiedBuild }
            catch StabilityLiveEvidenceError.unexpectedFailure { throw StabilityLiveEvidenceError.unexpectedFailure }
            catch StabilityLiveEvidenceError.contradictoryTerminal { throw StabilityLiveEvidenceError.contradictoryTerminal }
            catch { return false }
        }
        return proof
    }

    func evidence(actions: Int, failure: StabilityFailureOrigin? = nil, reason: StabilityLiveFailureReason? = nil) -> StabilityLiveStepEvidence {
        StabilityLiveStepEvidence(subjects: Array(subjects), observedUIActions: actions, expectedExtensionCodeHash: expectedExtensionCodeHash,
            conflictBarrierReached: conflictReached, cancellationObserved: cancellationObserved,
            workingSetMemberObserved: workingSetMember, failureOrigin: failure, failureReason: reason,
            supportingSpanIDs: failure == nil ? nil : (try? Array(Set(diagnostics().filter { $0.correlationID == correlationID && $0.subjectAlias.map(subjects.contains) == true }.compactMap(\.spanID)))),
            expectedActionsCodeHash: expectedActionsCodeHash, expectedWorkingSetMetadataAlias: expectedWorkingSetMetadataAlias)
    }

    func signal(_ identifier: NSFileProviderItemIdentifier) async throws {
        subject(identifier.rawValue)
        let manager = context.fileProviderManager
        try await StabilityCallbackWaiter<Void>().wait(timeout: deadline.remaining()) { completion in
            manager.signalEnumerator(for: identifier) { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    func stabilize() async throws {
        let manager = context.fileProviderManager
        try await StabilityCallbackWaiter<Void>().wait(timeout: deadline.remaining()) { completion in
            manager.waitForStabilization { error in
                if let error { completion(.failure(error)) } else { completion(.success(())) }
            }
        }
    }

    func poll(seconds: Int = 90, _ predicate: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: min(.seconds(seconds), self.deadline.remaining()))
        var delay = 2
        repeat {
            try Task.checkCancellation()
            do { if try await predicate() { return } }
            catch {
                guard let rejection = KDriveRemoteErrorClassifier.apiRejection(from: error), [408,429,500,502,503,504].contains(rejection.statusCode) else { throw error }
                delay = max(delay, rejection.retryAfterSeconds ?? delay)
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { break }
            try await Task.sleep(for: min(.seconds(delay), remaining))
            delay = min(delay * 2, 10)
        } while ContinuousClock.now < deadline
        throw FinderLiveError.timedOut
    }
}

enum FinderLiveError: Error {
    case missingRun, missingFixture, unsafeTarget, unverifiedBuild, invalidPagination, timedOut
    case assertionFailed, missingCapability, cancellationNotExercised
}
#endif
