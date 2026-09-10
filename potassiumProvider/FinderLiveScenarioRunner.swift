#if os(macOS) && STABILITY
import AppKit
import FileProvider
import PotassiumProviderCore

@MainActor
struct LiveFinderStabilityScenarioRunner: FinderStabilityScenarioRunning {
    let ui: any FinderUIDriving
    let conflictCase: StabilityLiveConflictCase?
    init(ui: (any FinderUIDriving)? = nil, conflictCase: StabilityLiveConflictCase? = nil) {
        self.ui = ui ?? SystemFinderUIDriver()
        self.conflictCase = conflictCase
    }

    func run(context: FinderStabilityLiveContext) async -> FinderStabilityScenarioExecution {
        var session: FinderLiveRunSession?
        var steps: [StabilityFinderStepResult] = []
        var observations: [StabilityFinderAPIObservation] = []
        var failed = false
        for (index, scenario) in StabilityFinderScenario.allCases.enumerated() {
            let startedAt = Date(), correlationID = UUID()
            let actionStart = ui.actionCount
            if let conflictCase, scenario != conflictCase.scenario {
                steps.append(step(index, scenario, correlationID, startedAt, .skipped(.notSelectedForConflictProfile)))
                continue
            }
            if failed {
                steps.append(step(index, scenario, correlationID, startedAt, .skipped(.earlierStepFailure)))
                continue
            }
            var pointerActive = false
            do {
                try await context.beginStep(correlationID)
                pointerActive = true
                if session == nil { session = try FinderLiveRunSession(context: context, ui: ui) }
                guard let session else { throw FinderLiveError.missingRun }
                try StabilityLiveStatus(state: .running, scenario: scenario).write(to: session.run)
                session.correlationID = correlationID
                session.subjects = []
                session.deadline = StabilityDeadline(budget: scenario == .cancellationAndProgress ? .seconds(600) : .seconds(90))
                ui.useDeadline { [weak session] in session?.deadline.remaining() ?? .zero }
                let (proof, stepObservations) = try await ProviderDiagnosticCorrelationContext.withCorrelation(correlationID) { @MainActor in
                    var stepObservations: [StabilityFinderAPIObservation] = []
                    if session.root == nil {
                        print("finder stability: preparing fixtures with a 90-second budget")
                        try await session.setup()
                        guard session.deadline.remaining() > .zero else { throw StabilityDeadlineError.expired }
                        // Preparation is a separate bounded operation. Keep its
                        // evidence and elapsed time, then start the navigation
                        // budget once the generated hierarchy is available.
                        session.deadline = StabilityDeadline(budget: .seconds(90))
                        print("finder stability: fixture preparation complete; starting scenario budget")
                    }
                    let baseline = try await session.list(session.require(session.root))
                    stepObservations.append(StabilityFinderAPIObservation(scenario: scenario, correlationID: correlationID, phase: .baseline,
                        outcome: .passed, recordedAt: Date(), hasMore: false, itemCount: baseline.count))
                    try await context.verifySafety()
                    print("finder stability step \(index + 1)/16: \(scenario.rawValue)")
                    if let conflictCase { try await session.executeConflict(conflictCase) }
                    else { try await execute(scenario, session: session) }
                    print("finder stability: UI interaction complete; recording evidence")
                    if let url = session.lastVisibleURL, ![.trash, .permanentDeletion].contains(scenario) {
                        try await ui.select(url)
                        try await ui.capture(in: session.run.directoryURL.appendingPathComponent("visual-evidence"), sequence: index + 1)
                    }
                    let proof = try await session.awaitDiagnostics(scenario: scenario, startedAt: startedAt, actions: ui.actionCount - actionStart)
                    let post = try await session.list(session.require(session.root))
                    stepObservations.append(StabilityFinderAPIObservation(scenario: scenario, correlationID: correlationID, phase: .postcondition,
                        outcome: .passed, recordedAt: Date(), hasMore: false, itemCount: post.count))
                    return (proof, stepObservations)
                }
                observations += stepObservations
                steps.append(step(index, scenario, correlationID, startedAt, .passed, proof: proof))
                try await context.endStep(correlationID)
                pointerActive = false
            } catch {
                if let session {
                    // The driver only captures its previously verified single
                    // generated selection; failure never broadens the region.
                    try? await ui.capture(in: session.run.directoryURL.appendingPathComponent("visual-evidence"), sequence: 100 + index)
                }
                if pointerActive { try? await context.endStep(correlationID) }
                let origin: StabilityFailureOrigin = (error as? FinderUIError) == .evictionResourceBusy ? .environment :
                    (error as? StabilityLiveEvidenceError) == .unexpectedFailure ? .provider : error is FinderUIError ? .automation :
                    (error is FinderLiveError || error is StabilityLiveEvidenceError || error is StabilityRunConfinementError ? .harness : .api)
                let reason = failureReason(error)
                let proof = session?.evidence(actions: ui.actionCount - actionStart, failure: origin, reason: reason)
                steps.append(step(index, scenario, correlationID, startedAt, .failed(.operationFailed), proof: proof))
                print("finder stability step failed: \(scenario.rawValue); origin \(origin.rawValue); reason \(reason.rawValue); class \(ProviderDiagnosticErrorClassifier.classify(error).rawValue)")
                if let uiError = error as? FinderUIError { print("finder stability UI failure: \(uiError.rawValue)") }
                if scenario == .enumerationAndChangeAnchors { await session?.diagnoseDirectoryDateRejection() }
                failed = true
            }
        }
        var canSeal = true
        // Failure screenshots are already retained. Keep monitoring through
        // window closure and the resulting provider callbacks before sealing.
        do { try await ui.closeOwnedWindows(); print("finder stability: run-owned Finder windows closed") }
        catch { canSeal = false; print("finder stability: Finder window cleanup failed; evidence will remain unsealed") }
        if let session {
            do { try StabilityLiveStatus(state: .settling).write(to: session.run); session.deadline = StabilityDeadline(budget: .seconds(600)); try await session.drain() }
            catch { canSeal = false; print("finder stability: pending extension work; evidence will remain unsealed") }
        }
        return FinderStabilityScenarioExecution(stepResults: steps, observations: observations, canSeal: canSeal)
    }

    private func failureReason(_ error: Error) -> StabilityLiveFailureReason {
        switch error {
        case FinderUIError.selectionMismatch: return .selectionMismatch
        case FinderUIError.windowMismatch: return .windowMismatch
        case FinderUIError.screenshotUnavailable: return .screenshotUnavailable
        case FinderUIError.controlUnavailable: return .unsupportedControl
        case FinderUIError.operatorCancelled: return .operatorStopped
        case FinderUIError.evictionResourceBusy: return .resourceBusy
        case FinderUIError.timedOut, FinderLiveError.timedOut, StabilityDeadlineError.expired: return .deadline
        case FinderLiveError.unsafeTarget, is StabilityRunConfinementError: return .unsafeTarget
        case FinderLiveError.unverifiedBuild: return .unverifiedBuild
        case FinderLiveError.missingFixture: return .missingFixture
        case FinderLiveError.cancellationNotExercised: return .cancellationNotExercised
        case FinderLiveError.assertionFailed: return .assertionFailed
        case is FinderUIError: return .uiUnavailable
        case StabilityLiveEvidenceError.unexpectedFailure: return .remoteError
        case is StabilityLiveEvidenceError: return .missingTelemetry
        default: return .remoteError
        }
    }

    private func step(_ index: Int, _ scenario: StabilityFinderScenario, _ correlationID: UUID, _ startedAt: Date,
                      _ outcome: StabilityFinderStepOutcome, proof: StabilityLiveStepEvidence? = nil) -> StabilityFinderStepResult {
        let untested: StabilityFinderAssertionNotEvaluatedReason
        if case .skipped = outcome { untested = .stepSkipped } else { untested = .operationDidNotReachAssertion }
        return StabilityFinderStepResult(sequenceNumber: UInt16(index + 1), scenario: scenario, correlationID: correlationID,
            startedAt: startedAt, finishedAt: Date(), outcome: outcome,
            assertions: StabilityFinderAssertionClass.allCases.map {
                StabilityFinderAssertionResult(assertionClass: $0, outcome: outcome == .passed ? .passed : .notEvaluated(untested))
            }, liveEvidence: proof)
    }

    private func execute(_ scenario: StabilityFinderScenario, session s: FinderLiveRunSession) async throws {
        let root = try s.require(s.root)
        switch scenario {
        case .enumerationAndChangeAnchors:
            let urls = try s.require(s.navigationURLs)
            let a = urls.nested, b = urls.deep, sibling = urls.sibling, rootURL = urls.root, seedURL = urls.seed
            try await FinderNavigationSequence.execute(using: ui, root: rootURL, nested: a, deep: b, sibling: sibling) { index, folder in
                // Select only a known generated child of the verified current
                // folder. This preserves history and keeps sidebars out of capture.
                let child: URL? = folder == rootURL ? a : folder == a ? b : folder == b ? seedURL : nil
                if let child {
                    try await ui.select(child)
                    try await ui.capture(in: s.run.directoryURL.appendingPathComponent("visual-evidence"), sequence: 200 + index)
                }
                // The sibling milestone is captured with its remote-change
                // fixture after that fixture becomes visible below.
            }
            print("finder stability: nested and history navigation verified")
            let changed = try await s.upload(name: "remote-change.txt", parent: s.require(s.sibling), data: Data("remote change\n".utf8))
            try await s.signal(NSFileProviderItemIdentifier(String(changed.parentID)))
            let changedURL = try await s.visible(changed)
            try await s.poll { try await ui.contains(changedURL) }
            print("finder stability: remote change visible in Finder")
            try await ui.select(changedURL)
        case .hydrate:
            let item = try s.require(s.seed), url = try await s.visible(item)
            try await ui.edit(url, contents: nil)
            try await s.waitBytes(item, expected: s.bytes)
            guard try Data(contentsOf: url) == s.bytes else { throw FinderLiveError.assertionFailed }
        case .evict:
            // Wait for both disk and provider changes to be acknowledged. This
            // is the system's testing barrier, not an API eviction substitute.
            try await s.stabilize()
            let url = try await s.visible(s.require(s.seed))
            try await ui.contextAction("Remove Download", on: url)
            // The menu state is inspected without opening or reading the evicted item.
            try await s.poll { try await ui.hasContextAction("Download Now", on: url) }
            guard try await ui.hasContextAction("Remove Download", on: url) == false else { throw FinderLiveError.assertionFailed }
            // Metadata lookup is non-hydrating; a new fetch is mandatory in the next step.
            _ = try await s.context.remote.item(driveID: s.context.domain.driveID, fileID: s.require(s.seed).id)
        case .download:
            let item = try s.require(s.seed), url = try await s.visible(item)
            try await ui.contextAction("Download Now", on: url)
            try await s.poll { try s.diagnostics().contains { $0.correlationID == s.correlationID && $0.operation == .fetchContents && $0.phase == .completed } }
            guard try Data(contentsOf: url) == s.bytes else { throw FinderLiveError.assertionFailed }
        case .fileCreate:
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(s.run.runID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let source = temporary.appendingPathComponent("created.txt")
            try s.bytes.write(to: source, options: .withoutOverwriting)
            try await ui.copy(source, to: s.visible(root))
            s.file = try await s.waitItem(named: source.lastPathComponent, parent: root)
            try await s.waitBytes(s.require(s.file), expected: s.bytes)
            _ = try await s.visible(s.require(s.file))
        case .directoryCreate:
            let parent = try s.require(s.deep)
            try await ui.createFolder(named: "Created Folder", in: s.visible(parent))
            s.directory = try await s.waitItem(named: "Created Folder", parent: parent)
            try await ui.navigate(to: s.visible(s.require(s.directory)))
        case .editAndUpload:
            let item = try s.require(s.file), url = try await s.visible(item)
            s.bytes = Data("stability file version two\n".utf8)
            try await ui.edit(url, contents: String(decoding: s.bytes, as: UTF8.self))
            try await s.waitBytes(item, expected: s.bytes)
        case .rename:
            let item = try s.require(s.file), url = try await s.visible(item)
            try await ui.rename(url, to: "renamed.txt")
            s.file = try await s.waitMetadata(item) { $0.name == "renamed.txt" && $0.id == item.id }
            try await s.poll { try await s.list(root).contains { $0.name == item.name } == false }
            _ = try await s.visible(s.require(s.file))
        case .move:
            let item = try s.require(s.file), parent = try s.require(s.directory)
            let source = try await s.visible(item), destination = try await s.visible(parent)
            try await s.bind(source, item: item)
            try await ui.move(source, to: destination)
            s.file = try await s.waitMetadata(item) { $0.parentID == parent.id && $0.name == item.name }
            try await s.waitBytes(item, expected: s.bytes)
            _ = try await s.visible(s.require(s.file))
        case .trash:
            let item = try s.require(s.file), url = try await s.visible(item)
            try await ui.select(url)
            try await ui.capture(in: s.run.directoryURL.appendingPathComponent("visual-evidence"), sequence: 10)
            try await ui.trash(url)
            try await s.waitTrashed(item, exists: true)
        case .restore:
            let item = try s.require(s.file), url = try await s.visible(item, trashed: true)
            try await ui.contextAction("Restore from kDrive Trash", on: url)
            s.file = try await s.waitRestored(item)
            try await s.waitBytes(item, expected: s.bytes)
            let restored = try await s.waitRestoredLocation(s.require(s.file))
            try await ui.select(restored)
        case .permanentDeletion:
            let item = try s.require(s.file), url = try await s.visible(item)
            try await ui.trash(url)
            try await s.waitTrashed(item, exists: true)
            let trashed = try await s.visible(item, trashed: true)
            try await ui.select(trashed)
            try await ui.capture(in: s.run.directoryURL.appendingPathComponent("visual-evidence"), sequence: 12)
            s.deadline.pause()
            try await ui.confirmPermanentDeletion(trashed, fixtureAlias: StabilityDiagnosticIdentity.alias(for: String(item.id), runID: s.run.runID))
            s.deadline.resume()
            try await s.bind(trashed, item: item, trashed: true)
            try await ui.contextAction("Delete Immediately…", on: trashed)
            try await ui.panelAction(.confirmSystemDeletion)
            try await s.waitDeleted(item)
        case .concurrentRemotePreserveBoth:
            try await s.preserveBoth()
        case .cancellationAndProgress:
            try await s.cancelTransfer()
        case .workingSetRefresh:
            let item = try s.require(s.transfer)
            try await ui.select(s.visible(item))
            try await s.verifyOwned(item)
            // A fresh remote metadata change makes a cached membership event
            // insufficient. The extension must deliver the new name through
            // its actual working-set enumeration before Finder can pass.
            try await s.context.remote.renameItem(driveID: s.context.domain.driveID, fileID: item.id, name: "working-set-current.bin")
            let current = try await s.waitMetadata(item) { $0.name == "working-set-current.bin" && $0.parentID == item.parentID }
            s.transfer = current
            s.expectedWorkingSetMetadataAlias = StabilityDiagnosticIdentity.metadataAlias(for: current, runID: s.run.runID)
            try await s.signal(.workingSet)
            guard let remote = s.context.remote as? any KDriveWorkingSetRemoteProviding else { throw FinderLiveError.missingCapability }
            try await s.poll {
                let items = try await remote.listWorkingSetRelevantItems(driveID: s.context.domain.driveID, latestLimit: 100)
                s.workingSetMember = items.contains { $0.id == item.id && $0.name == current.name && $0.parentID == current.parentID && $0.size == current.size }
                return s.workingSetMember
            }
            try await s.poll { try s.diagnostics().contains { $0.source == .fileProviderExtension &&
                $0.operation == .workingSetRefresh && $0.phase == .completed &&
                $0.itemMetadataAlias == s.expectedWorkingSetMetadataAlias && $0.correlationID == s.correlationID } }
            let currentURL = try await s.visible(current)
            try await ui.select(currentURL)
            guard try await ui.contains(currentURL) else { throw FinderLiveError.assertionFailed }
        case .supportedContextualActions:
            try await s.contextActions()
        }
    }
}
#endif
