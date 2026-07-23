import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@Suite
@MainActor
struct ProviderStatusPlacementTests {
    @Test func aggregatesOnlyPlacementStatesThatRequireAttention() throws {
        let states: [(String, ProviderDomainPlacementState)] = [
            ("connected", .connected),
            ("authentication", .authenticationRequired),
            ("disconnected", .volumeUnavailable),
            ("registering", .registering),
            ("moving", .moving),
            ("repair", .needsRepair("Choose Repair to reconnect this drive.")),
        ]
        let domains = states.enumerated().map { index, entry in
            makeDomain(
                configurationIdentifier: entry.0,
                domainIdentifier: "domain-\(index)",
                storageLocation: index == 2
                    ? .externalVolume(uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, displayName: "Archive SSD")
                    : .onThisMac
            )
        }
        let dashboard = makeDashboard(
            domains: domains,
            placementStates: Dictionary(uniqueKeysWithValues: states)
        )

        #expect(dashboard.summary.configuredDriveCount == 6)
        #expect(dashboard.summary.issueCount == 3)
        #expect(dashboard.drives.filter(\.placementRequiresAttention).count == 3)

        let connected = try #require(dashboard.drives.first { $0.id == "connected" })
        #expect(connected.issueCount == 0)
        #expect(connected.placementTitle == "Connected")

        let registering = try #require(dashboard.drives.first { $0.id == "registering" })
        #expect(registering.issueCount == 0)
        #expect(registering.placementTitle == "Registering")

        let moving = try #require(dashboard.drives.first { $0.id == "moving" })
        #expect(moving.issueCount == 0)
        #expect(moving.placementTitle == "Moving")

        let disconnected = try #require(dashboard.drives.first { $0.id == "disconnected" })
        #expect(disconnected.issueCount == 1)
        #expect(disconnected.storageTitle == "External Drive")
        #expect(disconnected.storageVolume == "Archive SSD")
        #expect(disconnected.storageDetail == "External Drive · Archive SSD")
        #expect(disconnected.placementTitle == "External Drive Disconnected")
        #expect(disconnected.placementDetail == "Connect the configured external drive to continue.")

        let repair = try #require(dashboard.drives.first { $0.id == "repair" })
        #expect(repair.issueCount == 1)
        #expect(repair.placementDetail == "Choose Repair to reconnect this drive.")
    }

    @Test func placementIssueAddsToExistingDriveAndAppIssues() throws {
        let domain = makeDomain(
            configurationIdentifier: "configuration-1",
            domainIdentifier: "domain-1"
        )
        let dashboard = ProviderStatusDashboard.make(
            input: ProviderStatusInput(
                accounts: [],
                domains: [domain],
                drivesByAccountIdentifier: [:],
                loadingDriveAccountIdentifiers: [],
                placementStatesByConfigurationIdentifier: [domain.configurationIdentifier: .authenticationRequired]
            ),
            snapshotStatistics: [],
            eventStatistics: [
                KDriveProviderEventDomainStatistics(
                    domainIdentifier: domain.domainIdentifier,
                    unresolvedConflictCount: 1,
                    blockedConflictCount: 1,
                    failedConflictCount: 1,
                    recentFailureCount: 2
                ),
                KDriveProviderEventDomainStatistics(
                    domainIdentifier: ProviderConstants.appActivityDomainIdentifier,
                    recentFailureCount: 2
                ),
            ],
            warnings: []
        )

        let drive = try #require(dashboard.drives.first)
        #expect(drive.issueCount == 6)
        #expect(dashboard.summary.issueCount == 8)
        #expect(drive.placementTitle == "Authentication Required")
        #expect(drive.placementRequiresAttention)
    }

    @Test func driveIdentityStaysStableWhenFileProviderDomainAndStorageChange() throws {
        let configurationIdentifier = "stable-configuration"
        let original = makeDomain(
            configurationIdentifier: configurationIdentifier,
            domainIdentifier: "local-domain"
        )
        let migrated = makeDomain(
            configurationIdentifier: configurationIdentifier,
            domainIdentifier: "NSFPExternal-generated-domain",
            storageLocation: .externalVolume(
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!,
                displayName: "Portable SSD"
            )
        )

        let originalDrive = try #require(makeDashboard(
            domains: [original],
            placementStates: [configurationIdentifier: .moving]
        ).drives.first)
        let migratedDrive = try #require(makeDashboard(
            domains: [migrated],
            placementStates: [configurationIdentifier: .connected]
        ).drives.first)

        #expect(originalDrive.id == configurationIdentifier)
        #expect(migratedDrive.id == configurationIdentifier)
        #expect(originalDrive.id == migratedDrive.id)
        #expect(originalDrive.domainIdentifier != migratedDrive.domainIdentifier)
        #expect(originalDrive.storageDetail == "On This Mac")
        #expect(migratedDrive.storageDetail == "External Drive · Portable SSD")
        #expect(originalDrive.placementTitle == "Moving")
        #expect(migratedDrive.placementTitle == "Connected")
    }

    private func makeDashboard(
        domains: [ProviderDomainConfiguration],
        placementStates: [String: ProviderDomainPlacementState]
    ) -> ProviderStatusDashboard {
        ProviderStatusDashboard.make(
            input: ProviderStatusInput(
                accounts: [],
                domains: domains,
                drivesByAccountIdentifier: [:],
                loadingDriveAccountIdentifiers: [],
                placementStatesByConfigurationIdentifier: placementStates
            ),
            snapshotStatistics: [],
            eventStatistics: [],
            warnings: []
        )
    }

    private func makeDomain(
        configurationIdentifier: String,
        domainIdentifier: String,
        storageLocation: ProviderDomainStorageLocation = .onThisMac
    ) -> ProviderDomainConfiguration {
        ProviderDomainConfiguration(
            domainIdentifier: domainIdentifier,
            configurationIdentifier: configurationIdentifier,
            accountIdentifier: "account-1",
            displayName: configurationIdentifier,
            driveID: 42,
            driveName: configurationIdentifier,
            storageLocation: storageLocation,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
