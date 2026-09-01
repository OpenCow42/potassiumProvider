#if os(macOS) && STABILITY
import AppKit
import ApplicationServices
import FileProvider
import Foundation
import PotassiumProviderCore

struct LiveFinderStabilityScenarioRunner: FinderStabilityScenarioRunning {
    private let fileManager = FileManager.default
    private let maximumPollAttempts = 60
    private let maximumPaginationPages = 100

    func run(context: FinderStabilityLiveContext) async -> FinderStabilityScenarioExecution {
        let state = LiveState()
        var results: [StabilityFinderStepResult] = []
        var observations: [StabilityFinderAPIObservation] = []
        var priorFailure = false

        for (index, scenario) in StabilityFinderScenario.allCases.enumerated() {
            let correlationID = UUID()
            let startedAt = Date()
            if priorFailure {
                results.append(skippedStep(
                    index: index,
                    scenario: scenario,
                    correlationID: correlationID,
                    startedAt: startedAt,
                    reason: .earlierStepFailure
                ))
                continue
            }

            var stepPointerIsActive = false
            do {
                try await context.beginStep(correlationID)
                stepPointerIsActive = true
                let (baseline, outcome) = try await ProviderDiagnosticCorrelationContext
                    .withCorrelation(correlationID) {
                        try await FinderStabilityScenarioGate.run(
                            baseline: { try await remoteItems(context: context) },
                            // Pagination may take time, so revalidate the
                            // shared-identity domain, visible root, remote root,
                            // and marker only after collecting the baseline and
                            // immediately before the scenario can mutate.
                            verifySafety: context.verifySafety,
                            execute: {
                                try await execute(
                                    scenario,
                                    context: context,
                                    state: state
                                )
                            }
                        )
                    }
                observations.append(StabilityFinderAPIObservation(
                    scenario: scenario,
                    correlationID: correlationID,
                    phase: .baseline,
                    outcome: .passed,
                    recordedAt: startedAt,
                    hasMore: false,
                    itemCount: baseline.count
                ))

                switch outcome {
                case .asserted(let finderVisible, let serverAuthoritative):
                    let postcondition = try await ProviderDiagnosticCorrelationContext
                        .withCorrelation(correlationID) {
                            try await remoteItems(context: context)
                        }
                    let finishedAt = Date()
                    let finderAssertion: StabilityFinderAssertionOutcome = finderVisible
                        ? .passed
                        : .failed(.stateMismatch)
                    let serverAssertion: StabilityFinderAssertionOutcome = serverAuthoritative
                        ? .passed
                        : .failed(.stateMismatch)
                    let passed = finderVisible && serverAuthoritative
                    let stepOutcome: StabilityFinderStepOutcome = passed
                        ? .passed
                        : .failed(.assertionFailed)
                    results.append(StabilityFinderStepResult(
                        sequenceNumber: UInt16(index + 1),
                        scenario: scenario,
                        correlationID: correlationID,
                        startedAt: startedAt,
                        finishedAt: finishedAt,
                        outcome: stepOutcome,
                        assertions: [
                            StabilityFinderAssertionResult(
                                assertionClass: .finderVisible,
                                outcome: finderAssertion
                            ),
                            StabilityFinderAssertionResult(
                                assertionClass: .serverAuthoritative,
                                outcome: serverAssertion
                            ),
                        ]
                    ))
                    observations.append(StabilityFinderAPIObservation(
                        scenario: scenario,
                        correlationID: correlationID,
                        phase: .postcondition,
                        outcome: passed ? .passed : .failed,
                        recordedAt: finishedAt,
                        hasMore: false,
                        itemCount: postcondition.count
                    ))
                    priorFailure = passed == false
                case .checkpoint(let reason):
                    let finishedAt = Date()
                    results.append(StabilityFinderStepResult(
                        sequenceNumber: UInt16(index + 1),
                        scenario: scenario,
                        correlationID: correlationID,
                        startedAt: startedAt,
                        finishedAt: finishedAt,
                        outcome: .checkpoint(reason),
                        assertions: StabilityFinderAssertionClass.allCases.map {
                            StabilityFinderAssertionResult(
                                assertionClass: $0,
                                outcome: .notEvaluated(.checkpointReached)
                            )
                        }
                    ))
                }
                try await context.endStep(correlationID)
                stepPointerIsActive = false
            } catch {
                if stepPointerIsActive {
                    try? await context.endStep(correlationID)
                }
                let finishedAt = Date()
                results.append(StabilityFinderStepResult(
                    sequenceNumber: UInt16(index + 1),
                    scenario: scenario,
                    correlationID: correlationID,
                    startedAt: startedAt,
                    finishedAt: finishedAt,
                    outcome: .failed(.operationFailed),
                    assertions: StabilityFinderAssertionClass.allCases.map {
                        StabilityFinderAssertionResult(
                            assertionClass: $0,
                            outcome: .notEvaluated(.operationDidNotReachAssertion)
                        )
                    }
                ))
                priorFailure = true
            }
        }

        return FinderStabilityScenarioExecution(
            stepResults: results,
            observations: observations
        )
    }

    private func execute(
        _ scenario: StabilityFinderScenario,
        context: FinderStabilityLiveContext,
        state: LiveState
    ) async throws -> LiveOutcome {
        switch scenario {
        case .enumerationAndChangeAnchors:
            NSWorkspace.shared.activateFileViewerSelecting([context.rootURL])
            try await Task.sleep(for: .milliseconds(400))
            let finderReady = try raiseFinderWindow()
            try await signalAndStabilize(context.fileProviderManager, identifier: .rootContainer)
            let localItems = try fileManager.contentsOfDirectory(
                at: context.rootURL,
                includingPropertiesForKeys: nil
            )
            let serverItems = try await remoteItems(context: context)
            return .asserted(
                finderVisible: finderReady && localItems.isEmpty == false,
                serverAuthoritative: serverItems.contains {
                    $0.id == context.remoteConfiguration.ownershipMarkerFileID
                }
            )

        case .hydrate:
            let markerURL = try await visibleURL(
                manager: context.fileProviderManager,
                fileID: context.remoteConfiguration.ownershipMarkerFileID
            )
            state.markerURL = markerURL
            let localData = try Data(contentsOf: markerURL)
            let remoteData = try await context.remote.downloadFile(
                driveID: context.domain.driveID,
                fileID: context.remoteConfiguration.ownershipMarkerFileID
            )
            return .asserted(
                finderVisible: localData == remoteData,
                serverAuthoritative: remoteData.isEmpty == false
            )

        case .evict:
            let markerURL = try require(state.markerURL)
            let identifier = try await requireExpectedBinding(
                markerURL,
                fileID: context.remoteConfiguration.ownershipMarkerFileID,
                context: context
            )
            try await evict(identifier: identifier, manager: context.fileProviderManager)
            let remoteMarker = try await context.remote.item(
                driveID: context.domain.driveID,
                fileID: context.remoteConfiguration.ownershipMarkerFileID
            )
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: markerURL.path),
                serverAuthoritative: remoteMarker.id == context.remoteConfiguration.ownershipMarkerFileID
            )

        case .download:
            let markerURL = try require(state.markerURL)
            let localData = try Data(contentsOf: markerURL)
            let remoteData = try await context.remote.downloadFile(
                driveID: context.domain.driveID,
                fileID: context.remoteConfiguration.ownershipMarkerFileID
            )
            return .asserted(finderVisible: localData == remoteData, serverAuthoritative: true)

        case .fileCreate:
            let name = "stability-file-\(UUID().uuidString).bin"
            let url = context.rootURL.appendingPathComponent(name)
            let data = Data("stability-file-v1".utf8)
            try data.write(to: url, options: .atomic)
            try await stabilize(context.fileProviderManager)
            let item = try await waitForRemoteItem(
                context: context,
                parentID: context.domain.rootFileID,
                name: name,
                shouldExist: true
            )
            state.fileName = name
            state.fileURL = url
            state.fileID = item?.id
            state.fileData = data
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: url.path),
                serverAuthoritative: item != nil
            )

        case .directoryCreate:
            let name = "stability-directory-\(UUID().uuidString)"
            let url = context.rootURL.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            try await stabilize(context.fileProviderManager)
            let item = try await waitForRemoteItem(
                context: context,
                parentID: context.domain.rootFileID,
                name: name,
                shouldExist: true
            )
            state.directoryName = name
            state.directoryURL = url
            state.directoryID = item?.id
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: url.path),
                serverAuthoritative: item?.isDirectory == true
            )

        case .editAndUpload:
            let url = try require(state.fileURL)
            let fileID = try require(state.fileID)
            let data = Data("stability-file-v2".utf8)
            try await requireExpectedBinding(url, fileID: fileID, context: context)
            try data.write(to: url, options: .atomic)
            try await stabilize(context.fileProviderManager)
            let remoteData = try await waitForRemoteData(
                context: context,
                fileID: fileID,
                expected: data
            )
            state.fileData = data
            return .asserted(
                finderVisible: try Data(contentsOf: url) == data,
                serverAuthoritative: remoteData == data
            )

        case .rename:
            let oldURL = try require(state.fileURL)
            let fileID = try require(state.fileID)
            let oldName = try require(state.fileName)
            let newName = "stability-renamed-\(UUID().uuidString).bin"
            let newURL = context.rootURL.appendingPathComponent(newName)
            try await requireExpectedBinding(oldURL, fileID: fileID, context: context)
            try fileManager.moveItem(at: oldURL, to: newURL)
            try await stabilize(context.fileProviderManager)
            let renamed = try await waitForRemoteItem(
                context: context,
                parentID: context.domain.rootFileID,
                name: newName,
                shouldExist: true
            )
            let old = try await waitForRemoteItem(
                context: context,
                parentID: context.domain.rootFileID,
                name: oldName,
                shouldExist: false
            )
            state.fileName = newName
            state.fileURL = newURL
            state.fileID = renamed?.id
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: newURL.path),
                serverAuthoritative: renamed != nil && old == nil
            )

        case .move:
            let sourceURL = try require(state.fileURL)
            let directoryURL = try require(state.directoryURL)
            let directoryID = try require(state.directoryID)
            let fileID = try require(state.fileID)
            let name = try require(state.fileName)
            let destinationURL = directoryURL.appendingPathComponent(name)
            try await requireExpectedBinding(sourceURL, fileID: fileID, context: context)
            try await requireExpectedBinding(
                directoryURL,
                fileID: directoryID,
                context: context
            )
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            try await stabilize(context.fileProviderManager)
            let moved = try await waitForRemoteItem(
                context: context,
                parentID: directoryID,
                name: name,
                shouldExist: true
            )
            state.fileURL = destinationURL
            state.fileID = moved?.id
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: destinationURL.path),
                serverAuthoritative: moved?.parentID == directoryID
            )

        case .trash:
            let url = try require(state.fileURL)
            let fileID = try require(state.fileID)
            try await requireExpectedBinding(url, fileID: fileID, context: context)
            try await recycle(url)
            try await stabilize(context.fileProviderManager)
            let trashed = try await waitForTrashItem(
                context: context,
                fileID: fileID,
                shouldExist: true
            )
            state.fileID = trashed?.id
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: url.path) == false,
                serverAuthoritative: trashed != nil
            )

        case .restore:
            NSWorkspace.shared.activateFileViewerSelecting([context.rootURL])
            guard (try? raiseFinderWindow()) == true else {
                throw LiveRunnerError.finderUnavailable
            }
            // Never open the user-global Trash or imply that an unrelated item
            // is safe to restore. A future automated path must resolve the
            // exact provider-domain item by stable identifier first.
            return .checkpoint(.scopedRestoreWorkflowRequired)

        case .permanentDeletion:
            NSWorkspace.shared.activateFileViewerSelecting([context.rootURL])
            guard (try? raiseFinderWindow()) == true else {
                throw LiveRunnerError.finderUnavailable
            }
            // Permanent deletion is deliberately not directed through Finder's
            // global Trash. The verified lab root stays selected and no
            // irreversible mutation is attempted by the runner.
            return .checkpoint(.scopedPermanentDeletionWorkflowRequired)

        case .concurrentRemotePreserveBoth:
            return try await runPreserveBoth(context: context, state: state)

        case .cancellationAndProgress:
            return try await runCancellationAndProgress(context: context, state: state)

        case .workingSetRefresh:
            try await signalAndStabilize(context.fileProviderManager, identifier: .workingSet)
            guard let workingSetRemote = context.remote as? any KDriveWorkingSetRemoteProviding else {
                throw LiveRunnerError.workingSetUnavailable
            }
            let items = try await workingSetRemote.listWorkingSetRelevantItems(
                driveID: context.domain.driveID,
                latestLimit: 100
            )
            let candidateID = try require(state.workingSetCandidateID)
            let candidateURL = try await visibleURL(
                manager: context.fileProviderManager,
                fileID: candidateID
            )
            return .asserted(
                finderVisible: fileManager.fileExists(atPath: candidateURL.path),
                serverAuthoritative: items.contains { $0.id == candidateID }
            )

        case .supportedContextualActions:
            guard let directoryURL = state.directoryURL else {
                throw LiveRunnerError.contextActionsUnavailable
            }
            NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
            guard (try? raiseFinderWindow()) == true else {
                return .checkpoint(.variableContextualUI)
            }
            // Finder's contextual-menu hierarchy and localized labels are not
            // a stable automation contract. Stop at the documented operator
            // checkpoint instead of invoking the API directly and claiming
            // that Finder UI was exercised.
            return .checkpoint(.variableContextualUI)
        }
    }

    private func runPreserveBoth(
        context: FinderStabilityLiveContext,
        state: LiveState
    ) async throws -> LiveOutcome {
        let stepToken = UUID().uuidString
        let name = "stability-conflict-\(stepToken).bin"
        let url = context.rootURL.appendingPathComponent(name)
        let originalData = Data("stability-conflict-base-\(stepToken)".utf8)
        try originalData.write(to: url, options: .atomic)
        try await stabilize(context.fileProviderManager)
        let item = try require(try await waitForRemoteItem(
            context: context,
            parentID: context.domain.rootFileID,
            name: name,
            shouldExist: true
        ))
        guard let etag = item.etag else { throw LiveRunnerError.remoteStateUnavailable }

        let localData = Data("stability-conflict-local-\(stepToken)".utf8)
        let remoteData = Data("stability-conflict-remote-\(stepToken)".utf8)
        try await requireExpectedBinding(url, fileID: item.id, context: context)
        async let replacement = context.remote.replaceFile(
            driveID: context.domain.driveID,
            fileID: item.id,
            expectedETag: etag,
            clientToken: KDriveMutationIdentity.clientToken([
                "stability-finder-conflict", UUID().uuidString,
            ]),
            contentHash: KDriveMutationIdentity.contentHash(remoteData),
            contents: remoteData,
            lastModifiedAt: Date()
        )
        try localData.write(to: url, options: .atomic)
        _ = try await replacement
        try await stabilize(context.fileProviderManager)

        var localItemIDs: Set<Int> = []
        var remoteItemIDs: Set<Int> = []
        for candidate in try await remoteItems(context: context)
        where candidate.isDirectory == false
            && candidate.parentID == context.domain.rootFileID
            && (candidate.id == item.id || candidate.name.contains(stepToken)) {
            guard let data = try? await context.remote.downloadFile(
                driveID: context.domain.driveID,
                fileID: candidate.id
            ) else { continue }
            if data == localData { localItemIDs.insert(candidate.id) }
            if data == remoteData { remoteItemIDs.insert(candidate.id) }
        }
        state.conflictURL = url
        let preservedItemIDs = localItemIDs.union(remoteItemIDs)
        var finderVisibleItemIDs: Set<Int> = []
        for fileID in preservedItemIDs {
            guard let visibleURL = try? await visibleURL(
                manager: context.fileProviderManager,
                fileID: fileID
            ), fileManager.fileExists(atPath: visibleURL.path) else { continue }
            finderVisibleItemIDs.insert(fileID)
        }
        return .asserted(
            finderVisible: preservedItemIDs.count >= 2
                && finderVisibleItemIDs == preservedItemIDs,
            serverAuthoritative: localItemIDs.isEmpty == false
                && remoteItemIDs.isEmpty == false
                && localItemIDs.isDisjoint(with: remoteItemIDs)
        )
    }

    private func runCancellationAndProgress(
        context: FinderStabilityLiveContext,
        state: LiveState
    ) async throws -> LiveOutcome {
        let name = "stability-cancel-\(UUID().uuidString).bin"
        let data = Data(repeating: 0x5A, count: 8 * 1_024 * 1_024)
        let item = try await context.remote.uploadFile(
            driveID: context.domain.driveID,
            parentID: context.domain.rootFileID,
            fileName: name,
            contents: data,
            lastModifiedAt: Date(),
            conflictStrategy: .error,
            clientToken: KDriveMutationIdentity.clientToken([
                "stability-finder-cancel", UUID().uuidString,
            ]),
            contentHash: KDriveMutationIdentity.contentHash(data)
        )
        try await signalAndStabilize(context.fileProviderManager, identifier: .rootContainer)
        let url = try await visibleURL(manager: context.fileProviderManager, fileID: item.id)
        let identifier = try await requireExpectedBinding(
            url,
            fileID: item.id,
            context: context
        )
        try await evict(identifier: identifier, manager: context.fileProviderManager)
        state.workingSetCandidateID = item.id
        NSWorkspace.shared.activateFileViewerSelecting([url])
        guard (try? raiseFinderWindow()) == true else {
            throw LiveRunnerError.finderUnavailable
        }
        // Cancellation and progress controls are OS-owned Finder UI. Leave the
        // exact evicted item selected for the operator; do not start a transfer
        // that could outlive and be falsely sealed by this checkpointed run.
        return .checkpoint(.finderCancellationRequired)
    }

    private func remoteItems(
        context: FinderStabilityLiveContext,
        parentID: Int? = nil
    ) async throws -> [KDriveRemoteItem] {
        let folderID = parentID ?? context.domain.rootFileID
        var cursor: String?
        var seen: Set<String> = []
        var items: [KDriveRemoteItem] = []
        var pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= maximumPaginationPages else {
                throw LiveRunnerError.invalidPagination
            }
            let page = try await context.remote.listDirectory(
                driveID: context.domain.driveID,
                folderID: folderID,
                cursor: cursor,
                limit: 200
            )
            items.append(contentsOf: page.items)
            guard page.hasMore else { break }
            guard page.items.isEmpty == false else {
                throw LiveRunnerError.invalidPagination
            }
            guard let next = page.nextCursor, seen.insert(next).inserted else {
                throw LiveRunnerError.invalidPagination
            }
            cursor = next
        } while items.count <= StabilityLabResetPolicy.defaultMaximumRootChildren
        guard items.count <= StabilityLabResetPolicy.defaultMaximumRootChildren else {
            throw LiveRunnerError.invalidPagination
        }
        return items
    }

    private func trashItems(context: FinderStabilityLiveContext) async throws -> [KDriveRemoteItem] {
        var cursor: String?
        var seen: Set<String> = []
        var items: [KDriveRemoteItem] = []
        var pageCount = 0
        repeat {
            pageCount += 1
            guard pageCount <= maximumPaginationPages else {
                throw LiveRunnerError.invalidPagination
            }
            let page = try await context.remote.listTrash(
                driveID: context.domain.driveID,
                cursor: cursor,
                limit: 200
            )
            items.append(contentsOf: page.items)
            guard page.hasMore else { break }
            guard page.items.isEmpty == false else {
                throw LiveRunnerError.invalidPagination
            }
            guard let next = page.nextCursor, seen.insert(next).inserted else {
                throw LiveRunnerError.invalidPagination
            }
            cursor = next
        } while items.count <= StabilityLabResetPolicy.defaultMaximumRootChildren
        guard items.count <= StabilityLabResetPolicy.defaultMaximumRootChildren else {
            throw LiveRunnerError.invalidPagination
        }
        return items
    }

    private func waitForRemoteItem(
        context: FinderStabilityLiveContext,
        parentID: Int,
        name: String,
        shouldExist: Bool
    ) async throws -> KDriveRemoteItem? {
        for _ in 0..<maximumPollAttempts {
            let item = try await remoteItems(context: context, parentID: parentID).first {
                $0.name == name
            }
            if (item != nil) == shouldExist { return item }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LiveRunnerError.timedOut
    }

    private func waitForTrashItem(
        context: FinderStabilityLiveContext,
        fileID: Int,
        shouldExist: Bool
    ) async throws -> KDriveRemoteItem? {
        for _ in 0..<maximumPollAttempts {
            let item = try await trashItems(context: context).first { $0.id == fileID }
            if (item != nil) == shouldExist { return item }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LiveRunnerError.timedOut
    }

    private func waitForRemoteData(
        context: FinderStabilityLiveContext,
        fileID: Int,
        expected: Data
    ) async throws -> Data {
        for _ in 0..<maximumPollAttempts {
            if let data = try? await context.remote.downloadFile(
                driveID: context.domain.driveID,
                fileID: fileID
            ), data == expected {
                return data
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw LiveRunnerError.timedOut
    }

    private func waitForLocalExistence(
        _ url: URL,
        shouldExist: Bool
    ) async throws -> Bool {
        for _ in 0..<maximumPollAttempts {
            if fileManager.fileExists(atPath: url.path) == shouldExist { return true }
            try await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func visibleURL(
        manager: NSFileProviderManager,
        fileID: Int
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            manager.getUserVisibleURL(
                for: NSFileProviderItemIdentifier(String(fileID))
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: LiveRunnerError.localStateUnavailable)
                }
            }
        }
    }

    private func identifier(
        for url: URL
    ) async throws -> (NSFileProviderItemIdentifier, NSFileProviderDomainIdentifier) {
        try await withCheckedThrowingContinuation { continuation in
            NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                itemIdentifier, domainIdentifier, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let itemIdentifier, let domainIdentifier {
                    continuation.resume(returning: (itemIdentifier, domainIdentifier))
                } else {
                    continuation.resume(throwing: LiveRunnerError.localStateUnavailable)
                }
            }
        }
    }

    @discardableResult
    private func requireExpectedBinding(
        _ url: URL,
        fileID: Int,
        context: FinderStabilityLiveContext
    ) async throws -> NSFileProviderItemIdentifier {
        let rawItemIdentifier = try await FinderStabilityTargetBinding.resolve(
            expectedFileID: fileID,
            expectedDomainIdentifier: context.domain.domainIdentifier,
            using: {
                let resolved = try await identifier(for: url)
                return (resolved.0.rawValue, resolved.1.rawValue)
            }
        )
        return NSFileProviderItemIdentifier(rawItemIdentifier)
    }

    private func evict(
        identifier: NSFileProviderItemIdentifier,
        manager: NSFileProviderManager
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.evictItem(identifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func signalAndStabilize(
        _ manager: NSFileProviderManager,
        identifier: NSFileProviderItemIdentifier
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.signalEnumerator(for: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        try await stabilize(manager)
    }

    private func stabilize(_ manager: NSFileProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.waitForStabilization { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func recycle(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func raiseFinderWindow() throws -> Bool {
        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder"
        ).first else {
            throw LiveRunnerError.finderUnavailable
        }
        let application = AXUIElementCreateApplication(finder.processIdentifier)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
              let windows = rawWindows as? [AXUIElement],
              let window = windows.first else {
            throw LiveRunnerError.finderUnavailable
        }
        return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    }

    private func skippedStep(
        index: Int,
        scenario: StabilityFinderScenario,
        correlationID: UUID,
        startedAt: Date,
        reason: StabilityFinderStepSkipReason
    ) -> StabilityFinderStepResult {
        StabilityFinderStepResult(
            sequenceNumber: UInt16(index + 1),
            scenario: scenario,
            correlationID: correlationID,
            startedAt: startedAt,
            finishedAt: startedAt,
            outcome: .skipped(reason),
            assertions: StabilityFinderAssertionClass.allCases.map {
                StabilityFinderAssertionResult(
                    assertionClass: $0,
                    outcome: .notEvaluated(.stepSkipped)
                )
            }
        )
    }

    private func require<T>(_ value: T?) throws -> T {
        guard let value else { throw LiveRunnerError.localStateUnavailable }
        return value
    }
}

@MainActor
private final class LiveState {
    var markerURL: URL?
    var fileName: String?
    var fileURL: URL?
    var fileID: Int?
    var fileData: Data?
    var directoryName: String?
    var directoryURL: URL?
    var directoryID: Int?
    var conflictURL: URL?
    var workingSetCandidateID: Int?
}

private enum LiveOutcome: Sendable {
    case asserted(finderVisible: Bool, serverAuthoritative: Bool)
    case checkpoint(StabilityFinderCheckpointReason)
}

private enum LiveRunnerError: Error {
    case contextActionsUnavailable
    case finderUnavailable
    case invalidPagination
    case localStateUnavailable
    case remoteStateUnavailable
    case targetBindingMismatch
    case timedOut
    case workingSetUnavailable
}

enum FinderStabilityTargetBinding {
    static func resolve(
        expectedFileID: Int,
        expectedDomainIdentifier: String,
        using resolver: () async throws -> (itemIdentifier: String, domainIdentifier: String)
    ) async throws -> String {
        let actual = try await resolver()
        guard matches(
            expectedFileID: expectedFileID,
            expectedDomainIdentifier: expectedDomainIdentifier,
            actualItemIdentifier: actual.itemIdentifier,
            actualDomainIdentifier: actual.domainIdentifier
        ) else {
            throw LiveRunnerError.targetBindingMismatch
        }
        return actual.itemIdentifier
    }

    static func matches(
        expectedFileID: Int,
        expectedDomainIdentifier: String,
        actualItemIdentifier: String,
        actualDomainIdentifier: String
    ) -> Bool {
        actualItemIdentifier == String(expectedFileID)
            && actualDomainIdentifier == expectedDomainIdentifier
    }
}

@MainActor
enum FinderStabilityScenarioGate {
    static func run<Baseline, Outcome>(
        baseline: () async throws -> Baseline,
        verifySafety: () async throws -> Void,
        execute: () async throws -> Outcome
    ) async throws -> (Baseline, Outcome) {
        let baselineValue = try await baseline()
        try await verifySafety()
        let outcome = try await execute()
        return (baselineValue, outcome)
    }
}
#endif
