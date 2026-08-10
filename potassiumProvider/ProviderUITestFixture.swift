#if DEBUG
import Foundation
import PotassiumProviderCore

@MainActor
enum ProviderUITestFixture {
    private static let environmentKey = "POTASSIUM_UI_TEST_FIXTURE"

    static func makeModel() -> PotassiumProviderAppModel? {
        guard let fixtureName = ProcessInfo.processInfo.environment[environmentKey],
              [
                  "setup-navigation",
                  "setup-error-banner",
                  "activities-pagination",
                  "activities-action-errors",
                  "activities-unavailable",
                  "activities-row-action-errors",
              ].contains(fixtureName)
        else {
            return nil
        }

        if fixtureName == "activities-pagination" {
            return makeActivitiesModel()
        }
        if fixtureName == "activities-action-errors" {
            return PotassiumProviderAppModel(
                eventStore: ProviderUITestActivityStore(activity: [], failsExport: true),
                automaticallyReloadStoredState: false
            )
        }
        if fixtureName == "activities-unavailable" {
            return PotassiumProviderAppModel(
                eventStore: ProviderUITestUnavailableEventStore(),
                automaticallyReloadStoredState: false
            )
        }
        if fixtureName == "activities-row-action-errors" {
            let event = KDriveProviderActivityEvent(
                id: deterministicUUID(10_001),
                occurredAt: Date(timeIntervalSince1970: 2_000_000),
                domainIdentifier: "ui-domain",
                driveID: 10,
                kind: .enumeration,
                outcome: .failure,
                severity: .error,
                itemIdentifier: "missing-item",
                itemName: "Missing Item",
                itemPath: "/Missing Item",
                summary: "The item could not be enumerated."
            )
            return PotassiumProviderAppModel(
                eventStore: ProviderUITestActivityStore(activity: [event]),
                automaticallyReloadStoredState: false
            )
        }

        let account = ProviderAccount(
            accountIdentifier: "ui-account",
            displayName: "Design Team",
            authenticationKind: .oauth
        )
        let configuredDrive = KDriveDriveSummary(
            id: 10,
            name: "Shared Projects",
            accountID: 1,
            ownership: .owned,
            role: "admin",
            status: "active",
            isInMaintenance: false
        )
        let availableDrive = KDriveDriveSummary(
            id: 20,
            name: "Archive",
            accountID: 1,
            ownership: .owned,
            role: "user",
            status: "maintenance",
            isInMaintenance: true
        )
        let configuration = ProviderDomainConfiguration(
            domainIdentifier: "ui-domain",
            accountIdentifier: account.accountIdentifier,
            displayName: configuredDrive.name,
            driveID: configuredDrive.id,
            driveName: configuredDrive.name
        )
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("potassiumProviderUITestFixture", isDirectory: true)

        let model = PotassiumProviderAppModel(
            accountStore: ProviderAccountFileStore(
                directoryURL: fixtureDirectory.appendingPathComponent("Accounts", isDirectory: true)
            ),
            domainStore: DomainConfigurationFileStore(
                directoryURL: fixtureDirectory.appendingPathComponent("Domains", isDirectory: true)
            ),
            tokenStore: InMemoryOAuthTokenStore(),
            oauthAuthenticator: ProviderUITestOAuthAuthenticator(),
            domainRegistrar: ProviderUITestDomainRegistrar(),
            automaticallyReloadStoredState: false,
            initialAccounts: [account],
            initialDrivesByAccountIdentifier: [
                account.accountIdentifier: [configuredDrive, availableDrive],
            ],
            initialDomains: [configuration],
            encryptedVaultsEnabled: true
        )
        if fixtureName == "setup-error-banner" {
            model.errorMessage = "Could not refresh kDrive details."
        }
        return model
    }

    private static func makeActivitiesModel() -> PotassiumProviderAppModel {
        let activity = (0..<1_000).map { index in
            KDriveProviderActivityEvent(
                id: deterministicUUID(index),
                occurredAt: Date(timeIntervalSince1970: Double(2_000_000 - index)),
                domainIdentifier: "ui-domain",
                driveID: 10,
                kind: .enumeration,
                outcome: .failure,
                severity: .error,
                itemIdentifier: "\(index)",
                itemName: String(format: "Item %04d", index),
                itemPath: String(format: "/Item %04d", index),
                summary: String(format: "Deterministic activity %04d.", index),
                diagnostic: KDriveProviderActivityErrorDiagnostic(
                    errorCategory: .fileProvider,
                    recoverySuggestion: "Retry after the provider becomes available."
                )
            )
        }
        return PotassiumProviderAppModel(
            eventStore: ProviderUITestActivityStore(activity: activity),
            automaticallyReloadStoredState: false
        )
    }

    private static func deterministicUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
    }

    static func activityActionDependencies() -> ProviderActivityActionDependencies? {
        guard ProcessInfo.processInfo.environment[environmentKey] == "activities-row-action-errors"
        else {
            return nil
        }
        return ProviderActivityActionDependencies(
            itemOpener: ProviderItemOpening(
                resolve: { _, _ in
                    .resolved(URL(fileURLWithPath: "/Missing Item"))
                },
                present: { _ in false }
            ),
            copyAction: ProviderActivityCopyAction(write: { _ in false })
        )
    }

    static func initialActivityActionError() -> String? {
        guard ProcessInfo.processInfo.environment[environmentKey] == "activities-unavailable"
        else {
            return nil
        }
        return "Activity actions are unavailable while the database is closed."
    }
}

@MainActor
private final class ProviderUITestOAuthAuthenticator: KDriveOAuthAuthenticating {
    func authenticate() async throws -> KDriveOAuthToken {
        KDriveOAuthToken(
            accessToken: "ui-test-token",
            tokenType: "Bearer",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        )
    }
}

@MainActor
private struct ProviderUITestDomainRegistrar: ProviderDomainRegistering {
    func addDomain(for configuration: ProviderDomainConfiguration) async throws {}
    func removeDomain(for configuration: ProviderDomainConfiguration) async throws {}
}

private actor ProviderUITestActivityStore: KDriveProviderEventStoring, KDriveProviderEventTimelinePaging, KDriveProviderEventExporting {
    private var activity: [KDriveProviderActivityEvent]
    private let failsExport: Bool

    init(activity: [KDriveProviderActivityEvent], failsExport: Bool = false) {
        self.activity = activity
        self.failsExport = failsExport
    }

    func saveConflict(_: KDriveConflictEvent) {}

    func recordActivity(_ event: KDriveProviderActivityEvent) {
        activity.removeAll { $0.id == event.id }
        activity.append(event)
    }

    func recentConflicts(domainIdentifier _: String?, limit _: Int) -> [KDriveConflictEvent] {
        []
    }

    func recentActivity(domainIdentifier _: String?, limit: Int) -> [KDriveProviderActivityEvent] {
        Array(activity.prefix(limit))
    }

    func recentActivity(
        domainIdentifier _: String?,
        outcome: KDriveProviderActivityOutcome?,
        limit: Int
    ) -> [KDriveProviderActivityEvent] {
        Array(activity.filter { outcome == nil || $0.outcome == outcome }.prefix(limit))
    }

    func removeActivityAndResolvedConflicts(domainIdentifier _: String?) {
        activity.removeAll()
    }

    func removeEvents(domainIdentifier: String) {
        activity.removeAll { $0.domainIdentifier == domainIdentifier }
    }

    func supportLogData(domainIdentifier _: String?) throws -> Data {
        if failsExport {
            throw ProviderUITestActivityError.exportFailed
        }
        return Data(#"{"formatVersion":1,"events":[]}"#.utf8)
    }

    func timelinePage(
        filter: KDriveProviderTimelineFilter,
        before cursor: KDriveProviderTimelineCursor?,
        limit: Int
    ) -> KDriveProviderTimelinePage {
        let entries = activity
            .filter { filter == .allActivity || $0.outcome == .failure }
            .map(KDriveProviderTimelineEntry.activity)
            .filter { entry in
                guard let cursor else { return true }
                return entry.cursor.date < cursor.date
                    || (
                        entry.cursor.date == cursor.date
                            && entry.cursor.eventID.uuidString < cursor.eventID.uuidString
                    )
            }
            .sorted {
                if $0.cursor.date != $1.cursor.date {
                    return $0.cursor.date > $1.cursor.date
                }
                return $0.cursor.eventID.uuidString > $1.cursor.eventID.uuidString
            }
        let pageEntries = Array(entries.prefix(limit))
        let hasMore = entries.count > pageEntries.count
        return KDriveProviderTimelinePage(
            entries: pageEntries,
            nextCursor: hasMore ? pageEntries.last?.cursor : nil,
            hasMore: hasMore
        )
    }
}

private actor ProviderUITestUnavailableEventStore: KDriveProviderEventStoring {
    func saveConflict(_: KDriveConflictEvent) {}

    func recordActivity(_: KDriveProviderActivityEvent) {}

    func recentConflicts(
        domainIdentifier _: String?,
        limit _: Int
    ) -> [KDriveConflictEvent] {
        []
    }

    func recentActivity(
        domainIdentifier _: String?,
        limit _: Int
    ) -> [KDriveProviderActivityEvent] {
        []
    }

    func recentActivity(
        domainIdentifier _: String?,
        outcome _: KDriveProviderActivityOutcome?,
        limit _: Int
    ) -> [KDriveProviderActivityEvent] {
        []
    }

    func removeActivityAndResolvedConflicts(domainIdentifier _: String?) {}

    func removeEvents(domainIdentifier _: String) {}
}

private enum ProviderUITestActivityError: LocalizedError {
    case exportFailed

    var errorDescription: String? {
        "The fixture could not create a support log."
    }
}
#endif
