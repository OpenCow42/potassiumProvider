import Foundation
import PotassiumProviderCore
import Testing

@Suite("kDrive contextual actions")
struct KDriveContextActionTests {
    @Test func directActionRoutingAndActivationMatchItemState() throws {
        #expect(ProviderDirectContextAction(
            rawValue: ProviderContextActionIdentifier.addFavorite
        ) == .addFavorite)
        #expect(ProviderDirectContextAction(
            rawValue: ProviderContextActionIdentifier.removeFavorite
        ) == .removeFavorite)
        #expect(ProviderDirectContextAction(
            rawValue: ProviderContextActionIdentifier.duplicate
        ) == .duplicate)
        #expect(ProviderDirectContextAction(
            rawValue: ProviderContextActionIdentifier.restoreFromTrash
        ) == .restoreFromTrash)

        let ordinary = ProviderContextItemState(
            isDirectory: false,
            isFavorite: false,
            isTrashed: false
        )
        #expect(ProviderDirectContextAction.addFavorite.isAvailable(for: ordinary))
        #expect(ProviderDirectContextAction.duplicate.isAvailable(for: ordinary))
        #expect(ProviderDirectContextAction.removeFavorite.isAvailable(for: ordinary) == false)
        #expect(ProviderDirectContextAction.restoreFromTrash.isAvailable(for: ordinary) == false)

        let favorite = ProviderContextItemState(
            isDirectory: true,
            isFavorite: true,
            isTrashed: false
        )
        #expect(ProviderDirectContextAction.removeFavorite.isAvailable(for: favorite))
        #expect(ProviderDirectContextAction.addFavorite.isAvailable(for: favorite) == false)

        let trashed = ProviderContextItemState(
            isDirectory: false,
            isFavorite: true,
            isTrashed: true
        )
        #expect(ProviderDirectContextAction.restoreFromTrash.isAvailable(for: trashed))
        #expect(ProviderDirectContextAction.addFavorite.isAvailable(for: trashed) == false)
        #expect(ProviderDirectContextAction.removeFavorite.isAvailable(for: trashed) == false)
        #expect(ProviderDirectContextAction.duplicate.isAvailable(for: trashed) == false)

        let root = ProviderContextItemState(
            isDirectory: true,
            isFavorite: false,
            isTrashed: false,
            isRoot: true
        )
        for action in ProviderDirectContextAction.allCases {
            #expect(action.isAvailable(for: root) == false)
        }
    }

    @Test func favoriteRefetchesMetadataAndInvalidatesBothParents() async throws {
        let current = item(id: 42, parentID: 10, isFavorite: false)
        let updated = item(id: 42, parentID: 11, isFavorite: true)
        let remote = ContextActionRemoteMock(
            metadataResponses: [42: [current, updated]]
        )
        let coordinator = KDriveContextActionCoordinator(
            driveID: 7,
            rootFileID: 1,
            remote: remote,
            actions: remote
        )

        let execution = try await coordinator.perform(.addFavorite, fileID: 42)

        #expect(execution.activityItem == updated)
        #expect(execution.affectedParentIDs == [10, 11])
        #expect(execution.invalidatesTrash == false)
        #expect(await remote.calls() == [
            .item(fileID: 42),
            .setFavorite(fileID: 42, isFavorite: true),
            .item(fileID: 42),
        ])
    }

    @Test func duplicateRefetchesAuthoritativeResultAndInvalidatesItsParent() async throws {
        let response = item(id: 99, parentID: 10, name: "Copy (pending)")
        let authoritative = item(id: 99, parentID: 12, name: "Copy")
        let remote = ContextActionRemoteMock(
            metadataResponses: [99: [authoritative]],
            duplicateResult: response
        )
        let coordinator = KDriveContextActionCoordinator(
            driveID: 7,
            rootFileID: 1,
            remote: remote,
            actions: remote
        )

        let execution = try await coordinator.perform(.duplicate, fileID: 42)

        #expect(execution.activityItem == authoritative)
        #expect(execution.affectedParentIDs == [12])
        #expect(await remote.calls() == [
            .duplicate(fileID: 42),
            .item(fileID: 99),
        ])
    }

    @Test func restoreUsesOriginalParentWhenItStillExists() async throws {
        let trashed = item(id: 42, parentID: 25)
        let remote = ContextActionRemoteMock(
            trashedResult: trashed,
            existingIDs: [25]
        )
        let coordinator = KDriveContextActionCoordinator(
            driveID: 7,
            rootFileID: 1,
            remote: remote,
            actions: remote
        )

        let execution = try await coordinator.perform(.restoreFromTrash, fileID: 42)

        #expect(execution.affectedParentIDs == [25])
        #expect(execution.invalidatesTrash)
        #expect(await remote.calls() == [
            .trashedItem(fileID: 42),
            .existingFileIDs([25]),
            .restore(fileID: 42, destinationParentID: 25),
        ])
    }

    @Test func restoreFallsBackToRootWithoutCorruptingStateOnFailure() async throws {
        let trashed = item(id: 42, parentID: 25)
        let remote = ContextActionRemoteMock(
            trashedResult: trashed,
            existingIDs: [],
            restoreError: ContextActionMockError.remoteFailure
        )
        let coordinator = KDriveContextActionCoordinator(
            driveID: 7,
            rootFileID: 1,
            remote: remote,
            actions: remote
        )

        await #expect(throws: ContextActionMockError.remoteFailure) {
            _ = try await coordinator.perform(.restoreFromTrash, fileID: 42)
        }
        #expect(await remote.calls() == [
            .trashedItem(fileID: 42),
            .existingFileIDs([25]),
            .restore(fileID: 42, destinationParentID: 1),
        ])
    }

    @Test func cancellationBeforeRoutingNeverStartsRemoteMutation() async {
        let remote = ContextActionRemoteMock(
            duplicateResult: item(id: 99, parentID: 1)
        )
        let coordinator = KDriveContextActionCoordinator(
            driveID: 7,
            rootFileID: 1,
            remote: remote,
            actions: remote
        )
        let task = Task {
            try await Task.sleep(for: .seconds(30))
            return try await coordinator.perform(.duplicate, fileID: 42)
        }

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(await remote.calls().isEmpty)
    }

    @Test func shareLinkDefaultsAreSecureAndPasswordsAreValidated() {
        let defaults = KDriveShareLinkConfiguration()
        #expect(defaults.access == .public)
        #expect(defaults.allowsDownload)
        #expect(defaults.allowsComments == false)
        #expect(defaults.allowsEditing == false)
        #expect(defaults.allowsAccessRequests == false)
        #expect(defaults.showsFileInformation)
        #expect(defaults.showsStatistics == false)
        #expect(defaults.validUntil == nil)
        #expect(defaults.isValid)

        var protected = defaults
        protected.access = .password
        #expect(protected.isValid == false)
        protected.password = "   "
        #expect(protected.isValid == false)
        protected.password = "memory-only password"
        #expect(protected.isValid)
        protected.password = nil
        #expect(protected.isValid(preservingPasswordFor: .password))
        #expect(protected.isValid(preservingPasswordFor: .public) == false)
    }

    @Test func restoredCopyNamePreservesExtensionAndUsesStableTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1_753_304_700)
        let timeZone = try #require(TimeZone(secondsFromGMT: 0))

        #expect(KDriveRestoredCopyNaming.filename(
            originalName: "Report.pdf",
            restoredAt: date,
            timeZone: timeZone,
            uniqueSuffix: "ABC123"
        ) == "Report (restored 2025-07-23 21.05 ABC123).pdf")
        #expect(KDriveRestoredCopyNaming.filename(
            originalName: "Archive",
            restoredAt: date,
            timeZone: timeZone,
            uniqueSuffix: "ABC123"
        ) == "Archive (restored 2025-07-23 21.05 ABC123)")
    }

    @Test func extensionPlistsUseSharedIdentifiersAndSingleSelectionPredicates() throws {
        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let providerActions = try actionDictionaries(
            at: repositoryURL.appendingPathComponent("Config/potassiumProviderFileProviderInfo.plist")
        )
        let uiActions = try actionDictionaries(
            at: repositoryURL.appendingPathComponent("Config/potassiumProviderActionsInfo.plist")
        )

        #expect(Set(providerActions.compactMap(actionIdentifier)) == Set(
            ProviderDirectContextAction.allCases.map(\.rawValue)
        ))
        #expect(Set(uiActions.compactMap(actionIdentifier)) == [
            ProviderContextActionIdentifier.shareLink,
            ProviderContextActionIdentifier.versionHistory,
        ])
        for action in providerActions + uiActions {
            let predicate = try #require(
                action["NSExtensionFileProviderActionActivationRule"] as? String
            )
            #expect(predicate.contains("fileproviderItems.@count == 1"))
        }
        let providerExtension = try extensionDictionary(
            at: repositoryURL.appendingPathComponent("Config/potassiumProviderFileProviderInfo.plist")
        )
        #expect(providerExtension["NSExtensionFileProviderSupportsFailingUploadOnConflict"] as? Bool == true)
    }

    private func actionDictionaries(at url: URL) throws -> [[String: Any]] {
        let extensionDictionary = try extensionDictionary(at: url)
        return try #require(
            extensionDictionary["NSExtensionFileProviderActions"] as? [[String: Any]]
        )
    }

    private func extensionDictionary(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )
        let root = try #require(propertyList as? [String: Any])
        return try #require(root["NSExtension"] as? [String: Any])
    }

    private func actionIdentifier(_ dictionary: [String: Any]) -> String? {
        dictionary["NSExtensionFileProviderActionIdentifier"] as? String
    }

    private func item(
        id: Int,
        parentID: Int,
        name: String = "Document.txt",
        isFavorite: Bool? = nil
    ) -> KDriveRemoteItem {
        KDriveRemoteItem(
            id: id,
            name: name,
            type: "file",
            status: "ok",
            driveID: 7,
            parentID: parentID,
            path: "/\(name)",
            size: 12,
            mimeType: "text/plain",
            isFavorite: isFavorite,
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 200),
            updatedAt: Date(timeIntervalSince1970: 300)
        )
    }
}

private actor ContextActionRemoteMock: KDriveItemMetadataProviding, KDriveContextActionProviding {
    enum Call: Equatable {
        case item(fileID: Int)
        case setFavorite(fileID: Int, isFavorite: Bool)
        case duplicate(fileID: Int)
        case trashedItem(fileID: Int)
        case existingFileIDs([Int])
        case restore(fileID: Int, destinationParentID: Int)
    }

    private var metadataResponses: [Int: [KDriveRemoteItem]]
    private let duplicateResult: KDriveRemoteItem?
    private let trashedResult: KDriveRemoteItem?
    private let existingIDs: Set<Int>
    private let restoreError: ContextActionMockError?
    private var recordedCalls: [Call] = []

    init(
        metadataResponses: [Int: [KDriveRemoteItem]] = [:],
        duplicateResult: KDriveRemoteItem? = nil,
        trashedResult: KDriveRemoteItem? = nil,
        existingIDs: Set<Int> = [],
        restoreError: ContextActionMockError? = nil
    ) {
        self.metadataResponses = metadataResponses
        self.duplicateResult = duplicateResult
        self.trashedResult = trashedResult
        self.existingIDs = existingIDs
        self.restoreError = restoreError
    }

    func calls() -> [Call] {
        recordedCalls
    }

    func item(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        recordedCalls.append(.item(fileID: fileID))
        guard var responses = metadataResponses[fileID], responses.isEmpty == false else {
            throw ContextActionMockError.missingFixture
        }
        let response = responses.removeFirst()
        metadataResponses[fileID] = responses
        return response
    }

    func setFavorite(driveID: Int, fileID: Int, isFavorite: Bool) async throws {
        recordedCalls.append(.setFavorite(fileID: fileID, isFavorite: isFavorite))
    }

    func duplicateItem(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        recordedCalls.append(.duplicate(fileID: fileID))
        guard let duplicateResult else {
            throw ContextActionMockError.missingFixture
        }
        return duplicateResult
    }

    func trashedItem(driveID: Int, fileID: Int) async throws -> KDriveRemoteItem {
        recordedCalls.append(.trashedItem(fileID: fileID))
        guard let trashedResult else {
            throw ContextActionMockError.missingFixture
        }
        return trashedResult
    }

    func existingFileIDs(driveID: Int, fileIDs: [Int]) async throws -> Set<Int> {
        recordedCalls.append(.existingFileIDs(fileIDs))
        return existingIDs
    }

    func restoreTrashedItem(
        driveID: Int,
        fileID: Int,
        destinationParentID: Int
    ) async throws {
        recordedCalls.append(.restore(fileID: fileID, destinationParentID: destinationParentID))
        if let restoreError {
            throw restoreError
        }
    }

    func shareLink(driveID: Int, fileID: Int) async throws -> KDriveShareLinkSummary? {
        throw ContextActionMockError.unimplemented
    }

    func createShareLink(
        driveID: Int,
        fileID: Int,
        configuration: KDriveShareLinkConfiguration
    ) async throws -> KDriveShareLinkSummary {
        throw ContextActionMockError.unimplemented
    }

    func updateShareLink(
        driveID: Int,
        fileID: Int,
        configuration: KDriveShareLinkConfiguration
    ) async throws -> KDriveShareLinkSummary {
        throw ContextActionMockError.unimplemented
    }

    func deleteShareLink(driveID: Int, fileID: Int) async throws {
        throw ContextActionMockError.unimplemented
    }

    func fileVersions(
        driveID: Int,
        fileID: Int,
        page: Int,
        pageSize: Int
    ) async throws -> KDriveFileVersionPage {
        throw ContextActionMockError.unimplemented
    }

    func restoreFileVersion(
        driveID: Int,
        fileID: Int,
        versionID: Int,
        destinationParentID: Int,
        name: String
    ) async throws -> KDriveRemoteItem {
        throw ContextActionMockError.unimplemented
    }
}

private enum ContextActionMockError: Error, Equatable {
    case missingFixture
    case remoteFailure
    case unimplemented
}
