import Foundation

/// A non-secret marker written to the disposable Stability Lab root and kept
/// locally with the lab configuration. Matching both copies is a prerequisite
/// for any reset plan.
public struct StabilityLabOwnershipMarker: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var identifier: UUID
    public var driveID: Int
    public var rootFileID: Int
    public var createdAt: Date

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        identifier: UUID = UUID(),
        driveID: Int,
        rootFileID: Int,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.driveID = driveID
        self.rootFileID = rootFileID
        self.createdAt = createdAt
    }
}

public enum StabilityLabRegisteredDomainPurpose: String, Codable, Equatable, Sendable {
    case ordinary
    case stabilityLab
}

/// The minimum registered-domain evidence required by the lab safety gate.
/// Display names and account identifiers are intentionally excluded.
public struct StabilityLabRegisteredDomain: Equatable, Sendable {
    public var purpose: StabilityLabRegisteredDomainPurpose
    public var driveID: Int
    public var rootFileID: Int
    public var encryptionMode: ProviderEncryptionMode
    public var ownershipMarkerIdentifier: UUID?

    public init(
        purpose: StabilityLabRegisteredDomainPurpose,
        driveID: Int,
        rootFileID: Int,
        encryptionMode: ProviderEncryptionMode,
        ownershipMarkerIdentifier: UUID? = nil
    ) {
        self.purpose = purpose
        self.driveID = driveID
        self.rootFileID = rootFileID
        self.encryptionMode = encryptionMode
        self.ownershipMarkerIdentifier = ownershipMarkerIdentifier
    }
}

/// Server-authoritative facts about the configured root. This type contains no
/// names, paths, URLs, or account identifiers. Its numeric remote identifiers
/// are still private operational state and must not be written to diagnostics.
public struct StabilityLabRootObservation: Equatable, Sendable {
    public var driveID: Int
    public var fileID: Int
    public var parentFileID: Int
    public var driveRootFileID: Int
    public var hasVerifiedLabOwnership: Bool
    public var ownershipMarker: StabilityLabOwnershipMarker?

    public init(
        driveID: Int,
        fileID: Int,
        parentFileID: Int,
        driveRootFileID: Int,
        hasVerifiedLabOwnership: Bool,
        ownershipMarker: StabilityLabOwnershipMarker?
    ) {
        self.driveID = driveID
        self.fileID = fileID
        self.parentFileID = parentFileID
        self.driveRootFileID = driveRootFileID
        self.hasVerifiedLabOwnership = hasVerifiedLabOwnership
        self.ownershipMarker = ownershipMarker
    }
}

public struct StabilityLabPreflightInput: Equatable, Sendable {
    public var expectedMarker: StabilityLabOwnershipMarker
    public var expectedOwnershipMarkerFileID: Int
    public var configuredEncryptionMode: ProviderEncryptionMode
    public var root: StabilityLabRootObservation
    public var registeredDomains: [StabilityLabRegisteredDomain]

    public init(
        expectedMarker: StabilityLabOwnershipMarker,
        expectedOwnershipMarkerFileID: Int,
        configuredEncryptionMode: ProviderEncryptionMode,
        root: StabilityLabRootObservation,
        registeredDomains: [StabilityLabRegisteredDomain]
    ) {
        self.expectedMarker = expectedMarker
        self.expectedOwnershipMarkerFileID = expectedOwnershipMarkerFileID
        self.configuredEncryptionMode = configuredEncryptionMode
        self.root = root
        self.registeredDomains = registeredDomains
    }
}

public enum StabilityLabPreflightIssue: String, Codable, Equatable, Hashable, Sendable {
    case unsupportedOwnershipMarkerVersion
    case invalidRootIdentity
    case invalidOwnershipMarkerFileIdentity
    case unsupportedEncryptedDomain
    case ordinaryDomainRegistered
    case driveRootSelected
    case rootIdentityMismatch
    case rootIsNotTopLevel
    case rootOwnershipNotVerified
    case ownershipMarkerMissing
    case ownershipMarkerMismatch
    case registeredLabDomainMissing
    case registeredLabDomainMismatch
    case multipleStabilityLabDomains
}

public struct StabilityLabPreflightResult: Equatable, Sendable {
    public let issues: [StabilityLabPreflightIssue]

    public var isAllowed: Bool {
        issues.isEmpty
    }

    fileprivate init(issues: [StabilityLabPreflightIssue]) {
        self.issues = issues
    }
}

/// An explicit confirmation bound to one marker and root. A confirmation for a
/// previous lab root cannot authorize a reset after reprovisioning.
public struct StabilityLabResetConfirmation: Equatable, Sendable {
    public static let requiredPhrase = "DELETE STABILITY LAB CONTENTS"

    fileprivate let marker: StabilityLabOwnershipMarker

    public init(
        typedPhrase: String,
        marker: StabilityLabOwnershipMarker
    ) throws {
        guard typedPhrase == Self.requiredPhrase else {
            throw StabilityLabResetConfirmationError.typedPhraseMismatch
        }
        self.marker = marker
    }
}

public enum StabilityLabResetConfirmationError: Error, Equatable, Sendable {
    case typedPhraseMismatch
}

public struct StabilityLabRootChild: Equatable, Sendable {
    public var fileID: Int
    public var parentFileID: Int

    public init(fileID: Int, parentFileID: Int) {
        self.fileID = fileID
        self.parentFileID = parentFileID
    }
}

/// `isComplete` must be backed by a fully consumed server listing. Reset never
/// plans from a partial page because the resulting evidence would be ambiguous.
public struct StabilityLabRootInventory: Equatable, Sendable {
    public var isComplete: Bool
    /// The separately persisted marker-file identity that must appear exactly
    /// once in the complete server-authoritative child listing.
    public var ownershipMarkerFileID: Int?
    public var children: [StabilityLabRootChild]

    public init(
        isComplete: Bool,
        ownershipMarkerFileID: Int?,
        children: [StabilityLabRootChild]
    ) {
        self.isComplete = isComplete
        self.ownershipMarkerFileID = ownershipMarkerFileID
        self.children = children
    }
}

public struct StabilityLabResetPolicy: Equatable, Sendable {
    public static let defaultMaximumRootChildren = 1_000

    public var maximumRootChildren: Int

    public init(maximumRootChildren: Int = Self.defaultMaximumRootChildren) {
        self.maximumRootChildren = maximumRootChildren
    }
}

public enum StabilityLabResetAction: Equatable, Sendable {
    /// Trashes one item whose authoritative parent is the preserved lab root.
    /// A directory may recursively contain lab-owned descendants, but the lab
    /// root itself is not representable as a reset action.
    case trashImmediateChild(fileID: Int)
}

public struct StabilityLabResetPlan: Equatable, Sendable {
    public let ownershipMarkerIdentifier: UUID
    public let preservedRootFileID: Int
    public let preservedOwnershipMarkerFileID: Int
    public let actions: [StabilityLabResetAction]

    /// Kept explicit for command/UI assertions. The plan type has no root
    /// deletion action, so this value cannot become true.
    public var deletesRoot: Bool { false }

    fileprivate init(
        ownershipMarkerIdentifier: UUID,
        preservedRootFileID: Int,
        preservedOwnershipMarkerFileID: Int,
        actions: [StabilityLabResetAction]
    ) {
        self.ownershipMarkerIdentifier = ownershipMarkerIdentifier
        self.preservedRootFileID = preservedRootFileID
        self.preservedOwnershipMarkerFileID = preservedOwnershipMarkerFileID
        self.actions = actions
    }
}

public enum StabilityLabResetPlanningError: Error, Equatable, Sendable {
    case preflightRejected([StabilityLabPreflightIssue])
    case confirmationDoesNotMatchRoot
    case invalidMaximumRootChildren
    case incompleteInventory
    case maximumRootChildrenExceeded(limit: Int)
    case ownershipMarkerFileEvidenceMissing
    case ownershipMarkerFileEvidenceDuplicate
    case ownershipMarkerFileEvidenceMismatch
    case ownershipMarkerFileIsNotImmediateChild
    case invalidContentIdentity
    case rootIncludedInContents
    case driveRootIncludedInContents
    case contentIsNotImmediateChild
    case duplicateContentIdentifier
}

extension StabilityLabResetConfirmationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .typedPhraseMismatch:
            "Type the exact destructive confirmation phrase before resetting the Stability Lab."
        }
    }
}

extension StabilityLabResetPlanningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .preflightRejected:
            "Stability Lab reset was rejected by the root safety preflight."
        case .confirmationDoesNotMatchRoot:
            "The destructive confirmation belongs to a different Stability Lab root."
        case .invalidMaximumRootChildren:
            "The configured Stability Lab reset limit is invalid."
        case .incompleteInventory:
            "The Stability Lab root inventory is incomplete."
        case .maximumRootChildrenExceeded(let limit):
            "The Stability Lab root contains more than the reset limit of \(limit) immediate items."
        case .ownershipMarkerFileEvidenceMissing:
            "The Stability Lab ownership-marker file is missing from the complete root inventory."
        case .ownershipMarkerFileEvidenceDuplicate:
            "The Stability Lab root inventory contains duplicate ownership-marker file evidence."
        case .ownershipMarkerFileEvidenceMismatch:
            "The Stability Lab root inventory identifies a different ownership-marker file."
        case .ownershipMarkerFileIsNotImmediateChild:
            "The Stability Lab ownership-marker file is not an immediate child of the lab root."
        case .invalidContentIdentity:
            "The Stability Lab root inventory contains an invalid item identity."
        case .rootIncludedInContents:
            "The Stability Lab root cannot be included in its reset contents."
        case .driveRootIncludedInContents:
            "The drive root cannot be included in Stability Lab reset contents."
        case .contentIsNotImmediateChild:
            "Every Stability Lab reset target must be an immediate child of the lab root."
        case .duplicateContentIdentifier:
            "The Stability Lab root inventory contains a duplicate item identity."
        }
    }
}

/// Pure safety decisions shared by the app command and tests. Remote listing,
/// marker persistence, confirmation UI, and deletion execution stay injected
/// outside this namespace.
public enum StabilityLabSafety {
    public static func preflight(
        _ input: StabilityLabPreflightInput
    ) -> StabilityLabPreflightResult {
        var issues: [StabilityLabPreflightIssue] = []

        func record(_ issue: StabilityLabPreflightIssue) {
            if issues.contains(issue) == false {
                issues.append(issue)
            }
        }

        let marker = input.expectedMarker
        let root = input.root

        if marker.schemaVersion != StabilityLabOwnershipMarker.currentSchemaVersion {
            record(.unsupportedOwnershipMarkerVersion)
        }
        if input.configuredEncryptionMode != .legacyPlaintext {
            record(.unsupportedEncryptedDomain)
        }
        if marker.driveID <= 0 || marker.rootFileID <= 0 ||
            root.driveID <= 0 || root.fileID <= 0 ||
            root.driveRootFileID != ProviderConstants.defaultRootFileID {
            record(.invalidRootIdentity)
        }
        if input.expectedOwnershipMarkerFileID <= 0 ||
            input.expectedOwnershipMarkerFileID == root.fileID ||
            input.expectedOwnershipMarkerFileID == root.driveRootFileID {
            record(.invalidOwnershipMarkerFileIdentity)
        }
        if root.fileID == root.driveRootFileID || marker.rootFileID == root.driveRootFileID {
            record(.driveRootSelected)
        }
        if root.driveID != marker.driveID || root.fileID != marker.rootFileID {
            record(.rootIdentityMismatch)
        }
        if root.parentFileID != root.driveRootFileID {
            record(.rootIsNotTopLevel)
        }
        if root.hasVerifiedLabOwnership == false {
            record(.rootOwnershipNotVerified)
        }

        switch root.ownershipMarker {
        case .none:
            record(.ownershipMarkerMissing)
        case .some(let observedMarker):
            if observedMarker.schemaVersion != StabilityLabOwnershipMarker.currentSchemaVersion {
                record(.unsupportedOwnershipMarkerVersion)
            }
            if observedMarker != marker {
                record(.ownershipMarkerMismatch)
            }
        }

        let stabilityDomains = input.registeredDomains.filter { domain in
            if domain.purpose == .ordinary {
                record(.ordinaryDomainRegistered)
            }
            if domain.encryptionMode != .legacyPlaintext {
                record(.unsupportedEncryptedDomain)
            }
            return domain.purpose == .stabilityLab
        }

        if stabilityDomains.isEmpty {
            record(.registeredLabDomainMissing)
        } else if stabilityDomains.count > 1 {
            record(.multipleStabilityLabDomains)
        }
        if stabilityDomains.contains(where: { domain in
            domain.driveID != marker.driveID ||
                domain.rootFileID != marker.rootFileID ||
                domain.ownershipMarkerIdentifier != marker.identifier
        }) {
            record(.registeredLabDomainMismatch)
        }

        return StabilityLabPreflightResult(issues: issues)
    }

    public static func planReset(
        input: StabilityLabPreflightInput,
        inventory: StabilityLabRootInventory,
        confirmation: StabilityLabResetConfirmation,
        policy: StabilityLabResetPolicy = StabilityLabResetPolicy()
    ) throws -> StabilityLabResetPlan {
        let preflightResult = preflight(input)
        guard preflightResult.isAllowed else {
            throw StabilityLabResetPlanningError.preflightRejected(preflightResult.issues)
        }
        guard confirmation.marker == input.expectedMarker else {
            throw StabilityLabResetPlanningError.confirmationDoesNotMatchRoot
        }
        guard policy.maximumRootChildren > 0 else {
            throw StabilityLabResetPlanningError.invalidMaximumRootChildren
        }
        guard inventory.isComplete else {
            throw StabilityLabResetPlanningError.incompleteInventory
        }

        guard let ownershipMarkerFileID = inventory.ownershipMarkerFileID else {
            throw StabilityLabResetPlanningError.ownershipMarkerFileEvidenceMissing
        }
        guard ownershipMarkerFileID == input.expectedOwnershipMarkerFileID else {
            throw StabilityLabResetPlanningError.ownershipMarkerFileEvidenceMismatch
        }
        let markerChildren = inventory.children.filter { child in
            child.fileID == ownershipMarkerFileID
        }
        guard markerChildren.isEmpty == false else {
            throw StabilityLabResetPlanningError.ownershipMarkerFileEvidenceMissing
        }
        guard markerChildren.count == 1 else {
            throw StabilityLabResetPlanningError.ownershipMarkerFileEvidenceDuplicate
        }

        let rootFileID = input.root.fileID
        guard markerChildren[0].parentFileID == rootFileID else {
            throw StabilityLabResetPlanningError.ownershipMarkerFileIsNotImmediateChild
        }

        let deletableChildCount = inventory.children.count - markerChildren.count
        guard deletableChildCount <= policy.maximumRootChildren else {
            throw StabilityLabResetPlanningError.maximumRootChildrenExceeded(
                limit: policy.maximumRootChildren
            )
        }

        let driveRootFileID = input.root.driveRootFileID
        var seenIdentifiers: Set<Int> = []
        var contentIdentifiers: [Int] = []
        contentIdentifiers.reserveCapacity(inventory.children.count)

        for child in inventory.children {
            if child.fileID == ownershipMarkerFileID {
                continue
            }
            guard child.fileID > 0 else {
                throw StabilityLabResetPlanningError.invalidContentIdentity
            }
            guard child.fileID != rootFileID else {
                throw StabilityLabResetPlanningError.rootIncludedInContents
            }
            guard child.fileID != driveRootFileID else {
                throw StabilityLabResetPlanningError.driveRootIncludedInContents
            }
            guard child.parentFileID == rootFileID else {
                throw StabilityLabResetPlanningError.contentIsNotImmediateChild
            }
            guard seenIdentifiers.insert(child.fileID).inserted else {
                throw StabilityLabResetPlanningError.duplicateContentIdentifier
            }
            contentIdentifiers.append(child.fileID)
        }

        let actions = contentIdentifiers
            .sorted()
            .map(StabilityLabResetAction.trashImmediateChild(fileID:))
        return StabilityLabResetPlan(
            ownershipMarkerIdentifier: input.expectedMarker.identifier,
            preservedRootFileID: rootFileID,
            preservedOwnershipMarkerFileID: ownershipMarkerFileID,
            actions: actions
        )
    }
}
