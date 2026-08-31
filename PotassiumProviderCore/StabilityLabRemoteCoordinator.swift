import Foundation

/// Remote identifiers and ownership proof for one disposable Stability Lab.
/// This value intentionally contains no display names, paths, URLs, or account
/// identifiers and must not itself be written to diagnostics.
public struct StabilityLabRemoteConfiguration: Equatable, Sendable {
    public let driveID: Int
    public let driveRootFileID: Int
    public let rootFileID: Int
    public let ownershipMarkerFileID: Int
    public let ownershipMarker: StabilityLabOwnershipMarker

    public init(
        driveID: Int,
        driveRootFileID: Int,
        rootFileID: Int,
        ownershipMarkerFileID: Int,
        ownershipMarker: StabilityLabOwnershipMarker
    ) {
        self.driveID = driveID
        self.driveRootFileID = driveRootFileID
        self.rootFileID = rootFileID
        self.ownershipMarkerFileID = ownershipMarkerFileID
        self.ownershipMarker = ownershipMarker
    }
}

public struct StabilityLabRemoteResetResult: Equatable, Sendable {
    public let trashedImmediateChildCount: Int

    public init(trashedImmediateChildCount: Int) {
        self.trashedImmediateChildCount = trashedImmediateChildCount
    }
}

public typealias StabilityLabRegisteredDomainsProvider =
    @Sendable () async throws -> [StabilityLabRegisteredDomain]

public enum StabilityLabRemoteCoordinatorError: Error, Equatable, Sendable {
    case invalidDriveRootIdentity
    case driveAccessNotVerified
    case ordinaryDomainRegistered
    case unsupportedRegisteredDomain
    case stabilityLabDomainAlreadyRegistered
    case invalidProvisionedRoot
    case invalidOwnershipMarkerFile
    case ownershipMarkerEncodingFailed
    case ownershipMarkerDecodingFailed
    case ownershipMarkerMismatch
    case invalidMaximumRootChildren
    case incompleteDirectoryPage
    case repeatedDirectoryCursor
    case maximumRootChildrenExceeded(limit: Int)
    case resetTargetIdentityChanged
}

extension StabilityLabRemoteCoordinatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDriveRootIdentity:
            "The selected Stability Lab drive root is invalid."
        case .driveAccessNotVerified:
            "The selected Stability Lab drive must be an available internal drive."
        case .ordinaryDomainRegistered:
            "Remove ordinary File Provider domains before provisioning a Stability Lab."
        case .unsupportedRegisteredDomain:
            "Stability Lab supports only legacy plaintext domains."
        case .stabilityLabDomainAlreadyRegistered:
            "A Stability Lab domain is already registered."
        case .invalidProvisionedRoot:
            "The server did not return the expected top-level Stability Lab folder."
        case .invalidOwnershipMarkerFile:
            "The server did not return the expected Stability Lab ownership-marker file."
        case .ownershipMarkerEncodingFailed:
            "The Stability Lab ownership marker could not be encoded."
        case .ownershipMarkerDecodingFailed:
            "The Stability Lab ownership marker could not be decoded."
        case .ownershipMarkerMismatch:
            "The remote Stability Lab ownership marker does not match local configuration."
        case .invalidMaximumRootChildren:
            "The configured Stability Lab reset limit is invalid."
        case .incompleteDirectoryPage:
            "The Stability Lab root listing ended without a continuation cursor."
        case .repeatedDirectoryCursor:
            "The Stability Lab root listing repeated a continuation cursor."
        case .maximumRootChildrenExceeded(let limit):
            "The Stability Lab root contains more than the reset limit of \(limit) immediate items."
        case .resetTargetIdentityChanged:
            "A Stability Lab reset target changed after planning; no mutation was performed for it."
        }
    }
}

/// Performs the narrowly scoped remote lifecycle for a disposable Stability
/// Lab. Credentials and domain registration remain outside this actor. All
/// destructive execution is derived from `StabilityLabSafety.planReset` and
/// uses trash, never permanent deletion.
public actor StabilityLabRemoteCoordinator {
    private static let markerFileName = ".potassium-stability-lab.json"
    private static let folderNamePrefix = "Potassium Stability Lab"
    private static let listingPageSize = 200

    private let remote: any KDriveFileProviding
    private let makeUUID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        remote: any KDriveFileProviding,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.remote = remote
        self.makeUUID = makeUUID
        self.now = now
    }

    /// Creates a uniquely named direct child of the explicit drive root and
    /// uploads a fixed-name ownership marker inside it. A partial provisioning
    /// result is left untouched for manual recovery; this method never rolls
    /// back with a destructive remote mutation.
    public func provision(
        driveID: Int,
        driveRootFileID: Int,
        registeredDomainsProvider: StabilityLabRegisteredDomainsProvider
    ) async throws -> StabilityLabRemoteConfiguration {
        try validateProvisioningDomains(try await registeredDomainsProvider())
        guard driveID > 0,
              driveRootFileID == ProviderConstants.defaultRootFileID else {
            throw StabilityLabRemoteCoordinatorError.invalidDriveRootIdentity
        }
        guard try await hasInternalDriveAccess(driveID) else {
            throw StabilityLabRemoteCoordinatorError.driveAccessNotVerified
        }

        let driveRoot = try await remote.item(driveID: driveID, fileID: driveRootFileID)
        guard driveRoot.id == driveRootFileID,
              driveRoot.driveID == driveID,
              driveRoot.isDirectory else {
            throw StabilityLabRemoteCoordinatorError.invalidDriveRootIdentity
        }

        try validateProvisioningDomains(try await registeredDomainsProvider())
        let identifier = makeUUID()
        let root = try await remote.createDirectory(
            driveID: driveID,
            parentID: driveRootFileID,
            name: "\(Self.folderNamePrefix) \(identifier.uuidString)"
        )
        guard root.id > 0,
              root.id != driveRootFileID,
              root.driveID == driveID,
              root.parentID == driveRootFileID,
              root.isDirectory else {
            throw StabilityLabRemoteCoordinatorError.invalidProvisionedRoot
        }

        try validateProvisioningDomains(try await registeredDomainsProvider())
        let marker = StabilityLabOwnershipMarker(
            identifier: identifier,
            driveID: driveID,
            rootFileID: root.id,
            createdAt: now()
        )
        let markerData = try encodeMarker(marker)
        let uploadedMarker = try await remote.uploadFile(
            driveID: driveID,
            parentID: root.id,
            fileName: Self.markerFileName,
            contents: markerData,
            lastModifiedAt: marker.createdAt,
            conflictStrategy: .error,
            clientToken: KDriveMutationIdentity.clientToken([
                "stability-lab-marker-create",
                identifier.uuidString
            ]),
            contentHash: KDriveMutationIdentity.contentHash(markerData)
        )
        guard uploadedMarker.id > 0,
              uploadedMarker.id != root.id,
              uploadedMarker.id != driveRootFileID,
              uploadedMarker.driveID == driveID,
              uploadedMarker.parentID == root.id,
              uploadedMarker.isDirectory == false else {
            throw StabilityLabRemoteCoordinatorError.invalidOwnershipMarkerFile
        }
        try validateProvisioningDomains(try await registeredDomainsProvider())

        let configuration = StabilityLabRemoteConfiguration(
            driveID: driveID,
            driveRootFileID: driveRootFileID,
            rootFileID: root.id,
            ownershipMarkerFileID: uploadedMarker.id,
            ownershipMarker: marker
        )
        let finalizedObservation = try await observe(configuration: configuration)
        guard finalizedObservation.hasVerifiedLabOwnership else {
            throw StabilityLabRemoteCoordinatorError.driveAccessNotVerified
        }
        return configuration
    }

    /// Fetches both server objects and downloads the marker before returning
    /// root evidence. Remote names and paths are deliberately discarded.
    public func observe(
        configuration: StabilityLabRemoteConfiguration
    ) async throws -> StabilityLabRootObservation {
        let hasInternalAccess = try await hasInternalDriveAccess(configuration.driveID)
        guard configuration.driveRootFileID == ProviderConstants.defaultRootFileID else {
            throw StabilityLabRemoteCoordinatorError.invalidDriveRootIdentity
        }
        let root = try await remote.item(
            driveID: configuration.driveID,
            fileID: configuration.rootFileID
        )
        guard root.id == configuration.rootFileID,
              root.driveID == configuration.driveID,
              root.parentID == configuration.driveRootFileID,
              root.isDirectory else {
            throw StabilityLabRemoteCoordinatorError.invalidProvisionedRoot
        }

        let markerItem = try await remote.item(
            driveID: configuration.driveID,
            fileID: configuration.ownershipMarkerFileID
        )
        guard markerItem.id == configuration.ownershipMarkerFileID,
              markerItem.driveID == configuration.driveID,
              markerItem.parentID == configuration.rootFileID,
              markerItem.isDirectory == false else {
            throw StabilityLabRemoteCoordinatorError.invalidOwnershipMarkerFile
        }

        let markerData = try await remote.downloadFile(
            driveID: configuration.driveID,
            fileID: configuration.ownershipMarkerFileID
        )
        let observedMarker: StabilityLabOwnershipMarker
        do {
            observedMarker = try JSONDecoder().decode(
                StabilityLabOwnershipMarker.self,
                from: markerData
            )
        } catch {
            throw StabilityLabRemoteCoordinatorError.ownershipMarkerDecodingFailed
        }
        guard observedMarker == configuration.ownershipMarker else {
            throw StabilityLabRemoteCoordinatorError.ownershipMarkerMismatch
        }

        return StabilityLabRootObservation(
            driveID: root.driveID,
            fileID: root.id,
            parentFileID: root.parentID,
            driveRootFileID: configuration.driveRootFileID,
            hasVerifiedLabOwnership: hasInternalAccess,
            ownershipMarker: observedMarker
        )
    }

    /// Fully consumes ordinary directory-listing pagination. A missing or
    /// repeated cursor and inventories larger than the configured bound fail
    /// closed rather than producing partial reset evidence.
    public func inventory(
        configuration: StabilityLabRemoteConfiguration,
        policy: StabilityLabResetPolicy = StabilityLabResetPolicy()
    ) async throws -> StabilityLabRootInventory {
        guard policy.maximumRootChildren > 0 else {
            throw StabilityLabRemoteCoordinatorError.invalidMaximumRootChildren
        }
        let (maximumListedChildren, overflow) = policy.maximumRootChildren.addingReportingOverflow(1)
        guard overflow == false else {
            throw StabilityLabRemoteCoordinatorError.invalidMaximumRootChildren
        }

        var cursor: String?
        var seenCursors: Set<String> = []
        var children: [StabilityLabRootChild] = []

        while true {
            let page = try await remote.listDirectory(
                driveID: configuration.driveID,
                folderID: configuration.rootFileID,
                cursor: cursor,
                limit: Self.listingPageSize
            )
            children.append(contentsOf: page.items.map { item in
                StabilityLabRootChild(fileID: item.id, parentFileID: item.parentID)
            })
            guard children.count <= maximumListedChildren else {
                throw StabilityLabRemoteCoordinatorError.maximumRootChildrenExceeded(
                    limit: policy.maximumRootChildren
                )
            }

            guard page.hasMore else {
                return StabilityLabRootInventory(
                    isComplete: true,
                    ownershipMarkerFileID: configuration.ownershipMarkerFileID,
                    children: children
                )
            }
            guard let nextCursor = page.nextCursor?.trimmingCharacters(in: .whitespacesAndNewlines),
                  nextCursor.isEmpty == false else {
                throw StabilityLabRemoteCoordinatorError.incompleteDirectoryPage
            }
            guard seenCursors.insert(nextCursor).inserted else {
                throw StabilityLabRemoteCoordinatorError.repeatedDirectoryCursor
            }
            cursor = nextCursor
        }
    }

    /// Plans from complete evidence, then revalidates the root, marker, and
    /// each immediate child directly before moving that child to trash.
    public func reset(
        configuration: StabilityLabRemoteConfiguration,
        configuredEncryptionMode: ProviderEncryptionMode,
        registeredDomainsProvider: StabilityLabRegisteredDomainsProvider,
        confirmation: StabilityLabResetConfirmation,
        policy: StabilityLabResetPolicy = StabilityLabResetPolicy()
    ) async throws -> StabilityLabRemoteResetResult {
        let registeredDomains = try await registeredDomainsProvider()
        let root = try await observe(configuration: configuration)
        let preflightInput = StabilityLabPreflightInput(
            expectedMarker: configuration.ownershipMarker,
            expectedOwnershipMarkerFileID: configuration.ownershipMarkerFileID,
            configuredEncryptionMode: configuredEncryptionMode,
            root: root,
            registeredDomains: registeredDomains
        )
        let rootInventory = try await inventory(configuration: configuration, policy: policy)
        let plan = try StabilityLabSafety.planReset(
            input: preflightInput,
            inventory: rootInventory,
            confirmation: confirmation,
            policy: policy
        )

        var trashedCount = 0
        for action in plan.actions {
            let targetFileID: Int
            switch action {
            case .trashImmediateChild(let fileID):
                targetFileID = fileID
            }

            let freshRoot = try await observe(configuration: configuration)
            let freshRegisteredDomains = try await registeredDomainsProvider()
            let freshPreflight = StabilityLabSafety.preflight(
                StabilityLabPreflightInput(
                    expectedMarker: configuration.ownershipMarker,
                    expectedOwnershipMarkerFileID: configuration.ownershipMarkerFileID,
                    configuredEncryptionMode: configuredEncryptionMode,
                    root: freshRoot,
                    registeredDomains: freshRegisteredDomains
                )
            )
            guard freshPreflight.isAllowed else {
                throw StabilityLabResetPlanningError.preflightRejected(freshPreflight.issues)
            }

            let target = try await remote.item(
                driveID: configuration.driveID,
                fileID: targetFileID
            )
            guard target.id == targetFileID,
                  target.driveID == configuration.driveID,
                  target.parentID == configuration.rootFileID,
                  target.id != configuration.rootFileID,
                  target.id != configuration.driveRootFileID,
                  target.id != configuration.ownershipMarkerFileID else {
                throw StabilityLabRemoteCoordinatorError.resetTargetIdentityChanged
            }

            try await remote.trashItem(
                driveID: configuration.driveID,
                fileID: targetFileID
            )
            trashedCount += 1
        }

        return StabilityLabRemoteResetResult(trashedImmediateChildCount: trashedCount)
    }

    private func validateProvisioningDomains(
        _ registeredDomains: [StabilityLabRegisteredDomain]
    ) throws {
        if registeredDomains.contains(where: { $0.purpose == .ordinary }) {
            throw StabilityLabRemoteCoordinatorError.ordinaryDomainRegistered
        }
        if registeredDomains.contains(where: { $0.encryptionMode != .legacyPlaintext }) {
            throw StabilityLabRemoteCoordinatorError.unsupportedRegisteredDomain
        }
        if registeredDomains.contains(where: { $0.purpose == .stabilityLab }) {
            throw StabilityLabRemoteCoordinatorError.stabilityLabDomainAlreadyRegistered
        }
    }

    private func hasInternalDriveAccess(_ driveID: Int) async throws -> Bool {
        let matchingDrives = try await remote.listDrives().filter { drive in
            drive.id == driveID
        }
        guard matchingDrives.count == 1, let drive = matchingDrives.first else {
            return false
        }
        return drive.isUsableInternalDrive && drive.isInMaintenance == false
    }

    private func encodeMarker(_ marker: StabilityLabOwnershipMarker) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(marker)
        } catch {
            throw StabilityLabRemoteCoordinatorError.ownershipMarkerEncodingFailed
        }
    }
}
