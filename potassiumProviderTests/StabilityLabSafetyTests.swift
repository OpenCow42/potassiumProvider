import Foundation
import PotassiumProviderCore
import Testing

@Suite("Stability Lab safety")
struct StabilityLabSafetyTests {
    @Test func ownershipMarkerRoundTripsWithoutAccountOrPathFields() throws {
        let marker = makeMarker()
        let data = try JSONEncoder().encode(marker)
        let encoded = try #require(String(data: data, encoding: .utf8))

        #expect(try JSONDecoder().decode(StabilityLabOwnershipMarker.self, from: data) == marker)
        #expect(encoded.contains("account") == false)
        #expect(encoded.contains("path") == false)
        #expect(encoded.contains("name") == false)
        #expect(encoded.contains("markerFileID") == false)
    }

    @Test func safeDedicatedPlaintextRootPassesPreflight() {
        let marker = makeMarker()
        let result = StabilityLabSafety.preflight(makeInput(marker: marker))

        #expect(result.isAllowed)
        #expect(result.issues.isEmpty)
    }

    @Test func preflightRejectsTheDriveRootEvenWhenItHasTheExpectedMarker() {
        let marker = makeMarker(rootFileID: 1)
        let input = makeInput(
            marker: marker,
            root: StabilityLabRootObservation(
                driveID: marker.driveID,
                fileID: marker.rootFileID,
                parentFileID: marker.rootFileID,
                driveRootFileID: marker.rootFileID,
                hasVerifiedLabOwnership: true,
                ownershipMarker: marker
            )
        )

        let result = StabilityLabSafety.preflight(input)

        #expect(result.isAllowed == false)
        #expect(result.issues.contains(.driveRootSelected))
    }

    @Test func preflightRejectsAnyOrdinaryRegisteredDomain() {
        let marker = makeMarker()
        let ordinary = StabilityLabRegisteredDomain(
            purpose: .ordinary,
            driveID: 400,
            rootFileID: 500,
            encryptionMode: .legacyPlaintext
        )
        let input = makeInput(marker: marker, registeredDomains: [ordinary])

        let result = StabilityLabSafety.preflight(input)

        #expect(result.isAllowed == false)
        #expect(result.issues.contains(.ordinaryDomainRegistered))
    }

    @Test func preflightRejectsBothOpaqueVaultFormats() {
        let marker = makeMarker()

        for mode in [ProviderEncryptionMode.opaqueVaultV1, .opaqueVaultV2] {
            let result = StabilityLabSafety.preflight(makeInput(
                marker: marker,
                configuredEncryptionMode: mode
            ))

            #expect(result.isAllowed == false)
            #expect(result.issues.contains(.unsupportedEncryptedDomain))
        }
    }

    @Test func preflightRejectsMissingAndMismatchedOwnershipMarkers() {
        let expected = makeMarker()
        let missing = StabilityLabSafety.preflight(makeInput(
            marker: expected,
            root: makeRoot(marker: expected, ownershipMarker: nil)
        ))
        let mismatchedMarker = StabilityLabOwnershipMarker(
            identifier: UUID(),
            driveID: expected.driveID,
            rootFileID: expected.rootFileID,
            createdAt: expected.createdAt
        )
        let mismatched = StabilityLabSafety.preflight(makeInput(
            marker: expected,
            root: makeRoot(marker: expected, ownershipMarker: mismatchedMarker)
        ))

        #expect(missing.issues.contains(.ownershipMarkerMissing))
        #expect(mismatched.issues.contains(.ownershipMarkerMismatch))
    }

    @Test func preflightRejectsMarkerAndObservedRootIdentityDrift() {
        let marker = makeMarker()
        let wrongRoot = StabilityLabRootObservation(
            driveID: marker.driveID,
            fileID: marker.rootFileID + 1,
            parentFileID: 1,
            driveRootFileID: 1,
            hasVerifiedLabOwnership: true,
            ownershipMarker: marker
        )
        let result = StabilityLabSafety.preflight(makeInput(marker: marker, root: wrongRoot))

        #expect(result.isAllowed == false)
        #expect(result.issues.contains(.rootIdentityMismatch))
    }

    @Test func preflightRejectsAnUnboundOwnershipMarkerFileIdentity() {
        let marker = StabilityLabOwnershipMarker(
            identifier: UUID(),
            driveID: 10,
            rootFileID: 20
        )

        let result = StabilityLabSafety.preflight(makeInput(
            marker: marker,
            expectedOwnershipMarkerFileID: 0
        ))

        #expect(result.isAllowed == false)
        #expect(result.issues.contains(.invalidOwnershipMarkerFileIdentity))
    }

    @Test func preflightRejectsRootsThatAreNotTopLevelOrLackVerifiedLabOwnership() {
        let marker = makeMarker()
        let root = StabilityLabRootObservation(
            driveID: marker.driveID,
            fileID: marker.rootFileID,
            parentFileID: 99,
            driveRootFileID: 1,
            hasVerifiedLabOwnership: false,
            ownershipMarker: marker
        )
        let result = StabilityLabSafety.preflight(makeInput(marker: marker, root: root))

        #expect(result.issues.contains(.rootIsNotTopLevel))
        #expect(result.issues.contains(.rootOwnershipNotVerified))
    }

    @Test func preflightRejectsStaleOrDuplicateLabRegistrations() {
        let marker = makeMarker()
        let stale = StabilityLabRegisteredDomain(
            purpose: .stabilityLab,
            driveID: marker.driveID,
            rootFileID: marker.rootFileID + 1,
            encryptionMode: .legacyPlaintext,
            ownershipMarkerIdentifier: marker.identifier
        )
        let matching = StabilityLabRegisteredDomain(
            purpose: .stabilityLab,
            driveID: marker.driveID,
            rootFileID: marker.rootFileID,
            encryptionMode: .legacyPlaintext,
            ownershipMarkerIdentifier: marker.identifier
        )
        let result = StabilityLabSafety.preflight(makeInput(
            marker: marker,
            registeredDomains: [stale, matching]
        ))

        #expect(result.issues.contains(.registeredLabDomainMismatch))
        #expect(result.issues.contains(.multipleStabilityLabDomains))
    }

    @Test func preflightRejectsAMissingRegisteredLabDomain() {
        let marker = makeMarker()
        let result = StabilityLabSafety.preflight(makeInput(
            marker: marker,
            registeredDomains: []
        ))

        #expect(result.isAllowed == false)
        #expect(result.issues.contains(.registeredLabDomainMissing))
    }

    @Test func destructiveConfirmationRequiresTheExactTypedPhrase() throws {
        let marker = makeMarker()

        for invalidPhrase in [
            "delete stability lab contents",
            "DELETE STABILITY LAB CONTENTS ",
            "DELETE STABILITY LAB",
            "",
        ] {
            #expect(throws: StabilityLabResetConfirmationError.typedPhraseMismatch) {
                _ = try StabilityLabResetConfirmation(typedPhrase: invalidPhrase, marker: marker)
            }
        }

        _ = try StabilityLabResetConfirmation(
            typedPhrase: StabilityLabResetConfirmation.requiredPhrase,
            marker: marker
        )
    }

    @Test func resetPlanDeletesOnlySortedImmediateRootContents() throws {
        let marker = makeMarker()
        let input = makeInput(marker: marker)
        let confirmation = try makeConfirmation(marker: marker)
        let inventory = makeInventory(
            marker: marker,
            children: [
                StabilityLabRootChild(fileID: 90, parentFileID: marker.rootFileID),
                StabilityLabRootChild(fileID: 40, parentFileID: marker.rootFileID),
            ]
        )

        let plan = try StabilityLabSafety.planReset(
            input: input,
            inventory: inventory,
            confirmation: confirmation
        )

        #expect(plan.actions == [
            .trashImmediateChild(fileID: 40),
            .trashImmediateChild(fileID: 90),
        ])
        #expect(plan.preservedRootFileID == marker.rootFileID)
        #expect(plan.preservedOwnershipMarkerFileID == ownershipMarkerFileID)
        #expect(plan.deletesRoot == false)
    }

    @Test func emptyCompleteInventoryProducesAValidNoOpPlan() throws {
        let marker = makeMarker()
        let plan = try StabilityLabSafety.planReset(
            input: makeInput(marker: marker),
            inventory: makeInventory(marker: marker),
            confirmation: makeConfirmation(marker: marker)
        )

        #expect(plan.actions.isEmpty)
        #expect(plan.deletesRoot == false)
    }

    @Test func resetPlanningRecomputesAndEnforcesPreflight() throws {
        let marker = makeMarker()
        let unsafeInput = makeInput(
            marker: marker,
            registeredDomains: [StabilityLabRegisteredDomain(
                purpose: .ordinary,
                driveID: marker.driveID,
                rootFileID: 700,
                encryptionMode: .legacyPlaintext
            )]
        )

        do {
            _ = try StabilityLabSafety.planReset(
                input: unsafeInput,
                inventory: makeInventory(marker: marker),
                confirmation: makeConfirmation(marker: marker)
            )
            Issue.record("Unsafe preflight unexpectedly produced a reset plan")
        } catch let error as StabilityLabResetPlanningError {
            guard case .preflightRejected(let issues) = error else {
                Issue.record("Unexpected reset planning error: \(error)")
                return
            }
            #expect(issues.contains(.ordinaryDomainRegistered))
        }
    }

    @Test func resetPlanningRejectsAConfirmationForAStaleRoot() throws {
        let current = makeMarker()
        let stale = makeMarker(rootFileID: current.rootFileID + 1)

        #expect(throws: StabilityLabResetPlanningError.confirmationDoesNotMatchRoot) {
            _ = try StabilityLabSafety.planReset(
                input: makeInput(marker: current),
                inventory: makeInventory(marker: current),
                confirmation: makeConfirmation(marker: stale)
            )
        }
    }

    @Test func resetPlanningRejectsIncompleteOrOversizedInventories() throws {
        let marker = makeMarker()
        let input = makeInput(marker: marker)
        let confirmation = try makeConfirmation(marker: marker)

        #expect(throws: StabilityLabResetPlanningError.incompleteInventory) {
            _ = try StabilityLabSafety.planReset(
                input: input,
                inventory: makeInventory(marker: marker, isComplete: false),
                confirmation: confirmation
            )
        }
        #expect(throws: StabilityLabResetPlanningError.maximumRootChildrenExceeded(limit: 1)) {
            _ = try StabilityLabSafety.planReset(
                input: input,
                inventory: makeInventory(
                    marker: marker,
                    children: [
                        StabilityLabRootChild(fileID: 40, parentFileID: marker.rootFileID),
                        StabilityLabRootChild(fileID: 41, parentFileID: marker.rootFileID),
                    ]
                ),
                confirmation: confirmation,
                policy: StabilityLabResetPolicy(maximumRootChildren: 1)
            )
        }
    }

    @Test func resetPlanningRejectsRootDriveRootWrongParentAndDuplicateTargets() throws {
        let marker = makeMarker()
        let input = makeInput(marker: marker)
        let confirmation = try makeConfirmation(marker: marker)

        let cases: [(StabilityLabRootInventory, StabilityLabResetPlanningError)] = [
            (
                makeInventory(
                    marker: marker,
                    children: [StabilityLabRootChild(fileID: marker.rootFileID, parentFileID: marker.rootFileID)]
                ),
                .rootIncludedInContents
            ),
            (
                makeInventory(
                    marker: marker,
                    children: [StabilityLabRootChild(fileID: 1, parentFileID: marker.rootFileID)]
                ),
                .driveRootIncludedInContents
            ),
            (
                makeInventory(
                    marker: marker,
                    children: [StabilityLabRootChild(fileID: 40, parentFileID: 999)]
                ),
                .contentIsNotImmediateChild
            ),
            (
                makeInventory(
                    marker: marker,
                    children: [
                        StabilityLabRootChild(fileID: 40, parentFileID: marker.rootFileID),
                        StabilityLabRootChild(fileID: 40, parentFileID: marker.rootFileID),
                    ]
                ),
                .duplicateContentIdentifier
            ),
        ]

        for (inventory, expectedError) in cases {
            #expect(throws: expectedError) {
                _ = try StabilityLabSafety.planReset(
                    input: input,
                    inventory: inventory,
                    confirmation: confirmation
                )
            }
        }
    }

    @Test func resetPlanningRejectsMissingOwnershipMarkerFileEvidence() throws {
        let marker = makeMarker()
        let input = makeInput(marker: marker)
        let confirmation = try makeConfirmation(marker: marker)

        let inventories = [
            StabilityLabRootInventory(
                isComplete: true,
                ownershipMarkerFileID: nil,
                children: [
                    StabilityLabRootChild(fileID: ownershipMarkerFileID, parentFileID: marker.rootFileID),
                ]
            ),
            StabilityLabRootInventory(
                isComplete: true,
                ownershipMarkerFileID: ownershipMarkerFileID,
                children: []
            ),
        ]

        for inventory in inventories {
            #expect(throws: StabilityLabResetPlanningError.ownershipMarkerFileEvidenceMissing) {
                _ = try StabilityLabSafety.planReset(
                    input: input,
                    inventory: inventory,
                    confirmation: confirmation
                )
            }
        }
    }

    @Test func resetPlanningRejectsDuplicateOwnershipMarkerFileEvidence() throws {
        let marker = makeMarker()
        let inventory = StabilityLabRootInventory(
            isComplete: true,
            ownershipMarkerFileID: ownershipMarkerFileID,
            children: [
                StabilityLabRootChild(fileID: ownershipMarkerFileID, parentFileID: marker.rootFileID),
                StabilityLabRootChild(fileID: ownershipMarkerFileID, parentFileID: marker.rootFileID),
            ]
        )

        #expect(throws: StabilityLabResetPlanningError.ownershipMarkerFileEvidenceDuplicate) {
            _ = try StabilityLabSafety.planReset(
                input: makeInput(marker: marker),
                inventory: inventory,
                confirmation: makeConfirmation(marker: marker)
            )
        }
    }

    @Test func resetPlanningRejectsMismatchedOrMisparentedOwnershipMarkerFileEvidence() throws {
        let marker = makeMarker()
        let confirmation = try makeConfirmation(marker: marker)
        let mismatched = StabilityLabRootInventory(
            isComplete: true,
            ownershipMarkerFileID: ownershipMarkerFileID + 1,
            children: [
                StabilityLabRootChild(fileID: ownershipMarkerFileID + 1, parentFileID: marker.rootFileID),
            ]
        )
        let misparented = StabilityLabRootInventory(
            isComplete: true,
            ownershipMarkerFileID: ownershipMarkerFileID,
            children: [
                StabilityLabRootChild(fileID: ownershipMarkerFileID, parentFileID: marker.rootFileID + 1),
            ]
        )

        #expect(throws: StabilityLabResetPlanningError.ownershipMarkerFileEvidenceMismatch) {
            _ = try StabilityLabSafety.planReset(
                input: makeInput(marker: marker),
                inventory: mismatched,
                confirmation: confirmation
            )
        }
        #expect(throws: StabilityLabResetPlanningError.ownershipMarkerFileIsNotImmediateChild) {
            _ = try StabilityLabSafety.planReset(
                input: makeInput(marker: marker),
                inventory: misparented,
                confirmation: confirmation
            )
        }
    }

    private func makeMarker(rootFileID: Int = 20) -> StabilityLabOwnershipMarker {
        StabilityLabOwnershipMarker(
            identifier: UUID(uuidString: "20EAF760-A682-4E38-BF1B-4EE4D33979F0")!,
            driveID: 10,
            rootFileID: rootFileID,
            createdAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }

    private func makeRoot(
        marker: StabilityLabOwnershipMarker,
        ownershipMarker: StabilityLabOwnershipMarker?
    ) -> StabilityLabRootObservation {
        StabilityLabRootObservation(
            driveID: marker.driveID,
            fileID: marker.rootFileID,
            parentFileID: 1,
            driveRootFileID: 1,
            hasVerifiedLabOwnership: true,
            ownershipMarker: ownershipMarker
        )
    }

    private func makeInput(
        marker: StabilityLabOwnershipMarker,
        expectedOwnershipMarkerFileID: Int = 30,
        configuredEncryptionMode: ProviderEncryptionMode = .legacyPlaintext,
        root: StabilityLabRootObservation? = nil,
        registeredDomains: [StabilityLabRegisteredDomain]? = nil
    ) -> StabilityLabPreflightInput {
        StabilityLabPreflightInput(
            expectedMarker: marker,
            expectedOwnershipMarkerFileID: expectedOwnershipMarkerFileID,
            configuredEncryptionMode: configuredEncryptionMode,
            root: root ?? makeRoot(marker: marker, ownershipMarker: marker),
            registeredDomains: registeredDomains ?? [
                StabilityLabRegisteredDomain(
                    purpose: .stabilityLab,
                    driveID: marker.driveID,
                    rootFileID: marker.rootFileID,
                    encryptionMode: .legacyPlaintext,
                    ownershipMarkerIdentifier: marker.identifier
                ),
            ]
        )
    }

    private func makeConfirmation(
        marker: StabilityLabOwnershipMarker
    ) throws -> StabilityLabResetConfirmation {
        try StabilityLabResetConfirmation(
            typedPhrase: StabilityLabResetConfirmation.requiredPhrase,
            marker: marker
        )
    }

    private func makeInventory(
        marker: StabilityLabOwnershipMarker,
        isComplete: Bool = true,
        children: [StabilityLabRootChild] = []
    ) -> StabilityLabRootInventory {
        StabilityLabRootInventory(
            isComplete: isComplete,
            ownershipMarkerFileID: ownershipMarkerFileID,
            children: [
                StabilityLabRootChild(
                    fileID: ownershipMarkerFileID,
                    parentFileID: marker.rootFileID
                ),
            ] + children
        )
    }

    private var ownershipMarkerFileID: Int { 30 }
}
