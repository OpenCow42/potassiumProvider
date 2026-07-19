import Combine
#if os(macOS)
import FileProvider
#endif
import Foundation
import OSLog
import PotassiumProviderCore

@MainActor
final class PotassiumProviderAppModel: ObservableObject {
    private static let log = ProviderLog.app

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var drivesByAccountIdentifier: [String: [KDriveDriveSummary]] = [:]
    @Published private(set) var domains: [ProviderDomainConfiguration] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var loadingDriveAccountIdentifiers: Set<String> = []
    @Published private(set) var knownFolderSyncStatesByConfigurationIdentifier: [String: ProviderKnownFolderSyncState] = [:]
    @Published private(set) var domainTransitionConfigurationIdentifiers: Set<String> = []
    @Published private(set) var placementStatesByConfigurationIdentifier: [String: ProviderDomainPlacementState] = [:]
    @Published var preservedDataLocation: ProviderPreservedDataLocation?
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    @Published var manualAccessToken = ""
    @Published var selectedDriveIDs: [String: Int] = [:]
    @Published var manualDriveIDs: [String: String] = [:]
    @Published var manualDriveNames: [String: String] = [:]

    private let accountStore: any ProviderAccountStoring
    private let domainStore: any DomainConfigurationStoring
    private let tokenStore: any OAuthTokenStoring
    private let oauthAuthenticator: any KDriveOAuthAuthenticating
    private let domainRegistrar: any ProviderDomainRegistering
    private let relocationJournalStore: any ProviderDomainRelocationJournaling
    private let externalVolumeSelector: any ProviderExternalVolumeSelecting
    private let snapshotStore: (any KDriveSnapshotStoring)?
    private let eventStore: (any KDriveProviderEventStoring)?
    private let fileProviderFactory: (String) -> any KDriveFileProviding
    private var automaticallyLoadedDriveAccountIdentifiers: Set<String> = []
    private var fileProviderDomainChangeCancellable: AnyCancellable?

    init(
        accountStore: (any ProviderAccountStoring)? = nil,
        domainStore: (any DomainConfigurationStoring)? = nil,
        tokenStore: (any OAuthTokenStoring)? = nil,
        oauthAuthenticator: (any KDriveOAuthAuthenticating)? = nil,
        domainRegistrar: (any ProviderDomainRegistering)? = nil,
        relocationJournalStore: (any ProviderDomainRelocationJournaling)? = nil,
        externalVolumeSelector: (any ProviderExternalVolumeSelecting)? = nil,
        snapshotStore: (any KDriveSnapshotStoring)? = nil,
        eventStore: (any KDriveProviderEventStoring)? = nil,
        automaticallyReloadStoredState: Bool = true,
        fileProviderFactory: @escaping (String) -> any KDriveFileProviding = { PotassiumKDriveService(bearerToken: $0) }
    ) {
        self.accountStore = accountStore ?? Self.makeDefaultAccountStore()
        self.domainStore = domainStore ?? Self.makeDefaultDomainStore()
        self.tokenStore = tokenStore ?? KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        self.oauthAuthenticator = oauthAuthenticator ?? KDriveOAuthWebAuthenticator()
        self.domainRegistrar = domainRegistrar ?? FileProviderDomainRegistrar()
        self.relocationJournalStore = relocationJournalStore ?? Self.makeDefaultRelocationJournalStore()
        self.externalVolumeSelector = externalVolumeSelector ?? ProviderExternalVolumeSelectionService()
        self.snapshotStore = snapshotStore ?? Self.makeDefaultSnapshotStore()
        self.eventStore = eventStore ?? Self.makeDefaultEventStore()
        self.fileProviderFactory = fileProviderFactory
        statusMessage = "No accounts connected."
        observeFileProviderDomainChanges()
        if automaticallyReloadStoredState {
            Task { await reloadStoredState() }
        }
    }

    var isConnected: Bool {
        accounts.isEmpty == false
    }

    var providerEventStore: (any KDriveProviderEventStoring)? {
        eventStore
    }

    var snapshotStatisticsProvider: (any KDriveSnapshotStatisticsProviding)? {
        snapshotStore as? any KDriveSnapshotStatisticsProviding
    }

    var providerEventStatisticsProvider: (any KDriveProviderEventStatisticsProviding)? {
        eventStore as? any KDriveProviderEventStatisticsProviding
    }

    func account(accountIdentifier: String) -> ProviderAccount? {
        accounts.first { $0.accountIdentifier == accountIdentifier }
    }

    func drives(for accountIdentifier: String) -> [KDriveDriveSummary] {
        drivesByAccountIdentifier[accountIdentifier] ?? []
    }

    func domains(for accountIdentifier: String) -> [ProviderDomainConfiguration] {
        domains.filter { $0.accountIdentifier == accountIdentifier }
    }

    func isLoadingDrives(for accountIdentifier: String) -> Bool {
        loadingDriveAccountIdentifiers.contains(accountIdentifier)
    }

    func canLoadDrives(for accountIdentifier: String) -> Bool {
        account(accountIdentifier: accountIdentifier) != nil && isLoadingDrives(for: accountIdentifier) == false
    }

    func loadDrivesForAccountsIfPossible() async {
        for account in accounts {
            await loadDrivesIfPossible(accountIdentifier: account.accountIdentifier)
        }
    }

    func canAddDomain(for accountIdentifier: String) -> Bool {
        resolvedDriveDraft(accountIdentifier: accountIdentifier) != nil
    }

    func isConfigured(accountIdentifier: String, driveID: Int) -> Bool {
        domains.contains { $0.accountIdentifier == accountIdentifier && $0.driveID == driveID }
    }

    func knownFolderSyncState(for configuration: ProviderDomainConfiguration) -> ProviderKnownFolderSyncState {
        knownFolderSyncStatesByConfigurationIdentifier[configuration.configurationIdentifier] ?? .unavailable
    }

    func isChangingKnownFolderSync(for configuration: ProviderDomainConfiguration) -> Bool {
        domainTransitionConfigurationIdentifiers.contains(configuration.configurationIdentifier)
    }

    func placementState(for configuration: ProviderDomainConfiguration) -> ProviderDomainPlacementState {
        placementStatesByConfigurationIdentifier[configuration.configurationIdentifier] ?? .registering
    }

    func isTransitioning(_ configuration: ProviderDomainConfiguration) -> Bool {
        domainTransitionConfigurationIdentifiers.contains(configuration.configurationIdentifier)
    }

    func canMutate(_ configuration: ProviderDomainConfiguration) -> Bool {
        guard isTransitioning(configuration) == false else { return false }
        switch placementState(for: configuration) {
        case .connected:
            return true
        case .authenticationRequired, .volumeUnavailable, .registering, .moving, .needsRepair:
            return false
        }
    }

    func selectExternalVolume() async -> ProviderExternalVolume? {
        do {
            let volume = try await externalVolumeSelector.selectExternalVolume()
            errorMessage = nil
            return volume
        } catch {
            errorMessage = "Could not inspect the external drive: \(error.localizedDescription)"
            statusMessage = nil
            return nil
        }
    }

    func selectedDriveID(for accountIdentifier: String) -> Int? {
        selectedDriveIDs[accountIdentifier]
    }

    func setSelectedDriveID(_ driveID: Int?, for accountIdentifier: String) {
        selectedDriveIDs[accountIdentifier] = driveID
        refreshDraftFromSelectedDrive(accountIdentifier: accountIdentifier)
    }

    func manualDriveID(for accountIdentifier: String) -> String {
        manualDriveIDs[accountIdentifier] ?? ""
    }

    func setManualDriveID(_ driveID: String, for accountIdentifier: String) {
        manualDriveIDs[accountIdentifier] = driveID
    }

    func manualDriveName(for accountIdentifier: String) -> String {
        manualDriveNames[accountIdentifier] ?? ""
    }

    func setManualDriveName(_ driveName: String, for accountIdentifier: String) {
        manualDriveNames[accountIdentifier] = driveName
    }

    func reloadStoredState() async {
        do {
            try await migrateLegacyStateIfNeeded()
            accounts = try await accountStore.allAccounts()
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            try await refreshDomainSystemStates()
            seedDraftState()

            if let synchronizationError = synchronizedState.registrationError {
                errorMessage = "Could not refresh Finder domain names: \(synchronizationError.localizedDescription)"
                statusMessage = nil
                await recordAppFailure(
                    kind: .domainManagement,
                    summary: "Could not refresh File Provider domain registration.",
                    error: synchronizationError,
                    category: .fileProvider
                )
            } else {
                errorMessage = nil
                statusMessage = accounts.isEmpty ? "No accounts connected." : "Loaded \(accounts.count) account\(accounts.count == 1 ? "" : "s")."
            }
        } catch {
            await recordAppFailure(
                kind: .runtimeLoading,
                summary: "Could not load saved provider state.",
                error: error,
                category: .storage
            )
            errorMessage = "Could not load saved provider state: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func connectWithOAuth() async {
        isConnecting = true
        errorMessage = nil
        statusMessage = "Opening Infomaniak login."
        defer { isConnecting = false }

        do {
            let token = try await oauthAuthenticator.authenticate()
            let account = try await createAccount(authenticationKind: .oauth, token: token)
            statusMessage = "Connected \(account.displayName). Loading kDrives."
            await loadDrives(accountIdentifier: account.accountIdentifier)
        } catch {
            await recordAppFailure(
                kind: .authentication,
                summary: "Could not connect with Infomaniak.",
                error: error,
                category: .authentication
            )
            errorMessage = "Could not connect with Infomaniak: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func saveManualAccessToken() async {
        let accessToken = manualAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard accessToken.isEmpty == false else {
            errorMessage = "Enter an access token before saving."
            statusMessage = nil
            return
        }

        let token = KDriveOAuthToken(
            accessToken: accessToken,
            tokenType: "Bearer",
            refreshToken: nil,
            scope: nil,
            idToken: nil,
            expiresAt: nil
        )

        do {
            let account = try await createAccount(authenticationKind: .manualAccessToken, token: token)
            manualAccessToken = ""
            statusMessage = "Access token saved for \(account.displayName). Loading kDrives."
            await loadDrives(accountIdentifier: account.accountIdentifier)
        } catch {
            await recordAppFailure(
                kind: .authentication,
                summary: "Could not save the access token.",
                error: error,
                category: .authentication
            )
            errorMessage = "Could not save the access token: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func loadDrives(accountIdentifier: String) async {
        guard let account = account(accountIdentifier: accountIdentifier) else {
            errorMessage = "Choose an account before loading kDrives."
            statusMessage = nil
            return
        }
        guard loadingDriveAccountIdentifiers.contains(accountIdentifier) == false else {
            return
        }

        loadingDriveAccountIdentifiers.insert(accountIdentifier)
        defer { loadingDriveAccountIdentifiers.remove(accountIdentifier) }

        do {
            let token = try await usableToken(accountIdentifier: accountIdentifier)
            errorMessage = nil

            let drives = try await fileProviderFactory(token.accessToken).listDrives()
            drivesByAccountIdentifier[accountIdentifier] = drives
            if selectedDriveIDs[accountIdentifier] == nil ||
                drives.contains(where: { $0.id == selectedDriveIDs[accountIdentifier] }) == false {
                selectedDriveIDs[accountIdentifier] = drives.first?.id
            }
            refreshDraftFromSelectedDrive(accountIdentifier: accountIdentifier)
            statusMessage = drives.isEmpty ? "No kDrives returned for \(account.displayName)." : "Loaded \(drives.count) kDrive\(drives.count == 1 ? "" : "s") for \(account.displayName)."
        } catch {
            await recordAppFailure(
                kind: .driveDiscovery,
                summary: "Could not load kDrives.",
                error: error,
                category: .api
            )
            errorMessage = "Could not load kDrives: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func addDomain(accountIdentifier: String) async {
        guard let account = account(accountIdentifier: accountIdentifier) else {
            errorMessage = "Choose an account before adding a domain."
            statusMessage = nil
            return
        }
        guard let draft = resolvedDriveDraft(accountIdentifier: accountIdentifier) else {
            errorMessage = "Choose or enter a kDrive before adding a domain."
            statusMessage = nil
            return
        }
        guard isConfigured(accountIdentifier: accountIdentifier, driveID: draft.id) == false else {
            errorMessage = "\(draft.name) is already available in Files for \(account.displayName)."
            statusMessage = nil
            return
        }

        var savedConfiguration: ProviderDomainConfiguration?
        do {
            let now = Date()
            let configuration = ProviderDomainConfiguration(
                accountIdentifier: accountIdentifier,
                displayName: ProviderDomainConfiguration.finderDisplayName(forDriveName: draft.name),
                driveID: draft.id,
                driveName: draft.name,
                createdAt: now,
                updatedAt: now
            )

            try await domainStore.save(configuration)
            savedConfiguration = configuration
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            if let registrationError = synchronizedState.registrationError {
                throw registrationError
            }
            try await refreshDomainSystemStates()
            statusMessage = "Added \(configuration.driveName) to Files."
            errorMessage = nil
        } catch {
            if let savedConfiguration {
                await rollbackFailedDomainAddition(savedConfiguration)
            }
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not add the provider domain.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not add the provider domain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func addDomain(accountIdentifier: String, drive: KDriveDriveSummary) async {
        selectedDriveIDs[accountIdentifier] = drive.id
        manualDriveIDs[accountIdentifier] = String(drive.id)
        manualDriveNames[accountIdentifier] = drive.name
        await addDomain(accountIdentifier: accountIdentifier)
    }

    func addDomain(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        externalVolume: ProviderExternalVolume
    ) async {
        selectedDriveIDs[accountIdentifier] = drive.id
        manualDriveIDs[accountIdentifier] = String(drive.id)
        manualDriveNames[accountIdentifier] = drive.name

        guard account(accountIdentifier: accountIdentifier) != nil else {
            errorMessage = "Choose an account before adding a domain."
            statusMessage = nil
            return
        }
        guard isConfigured(accountIdentifier: accountIdentifier, driveID: drive.id) == false else {
            errorMessage = "\(drive.name) is already available in Files."
            statusMessage = nil
            return
        }
        guard case .eligible = externalVolume.eligibility else {
            errorMessage = "Choose an eligible encrypted APFS drive."
            statusMessage = nil
            return
        }

        let configurationIdentifier = UUID().uuidString
        domainTransitionConfigurationIdentifiers.insert(configurationIdentifier)
        placementStatesByConfigurationIdentifier[configurationIdentifier] = .registering
        defer { domainTransitionConfigurationIdentifiers.remove(configurationIdentifier) }

        var savedConfiguration: ProviderDomainConfiguration?
        do {
            let configuration = try await externalVolumeSelector.withSecurityScopedAccess(
                to: externalVolume
            ) { volumeURL in
                let prepared = try self.domainRegistrar.prepareDomain(
                    configurationIdentifier: configurationIdentifier,
                    domainIdentifier: UUID().uuidString,
                    displayName: ProviderDomainConfiguration.finderDisplayName(forDriveName: drive.name),
                    target: .externalVolume(volumeURL)
                )
                guard let preparedVolumeUUID = prepared.volumeUUID,
                      preparedVolumeUUID == externalVolume.uuid
                else {
                    throw PotassiumProviderAppModelError.externalVolumeIdentityMismatch
                }

                let now = Date()
                let configuration = ProviderDomainConfiguration(
                    configurationIdentifier: configurationIdentifier,
                    domainIdentifier: prepared.domainIdentifier,
                    accountIdentifier: accountIdentifier,
                    displayName: ProviderDomainConfiguration.finderDisplayName(forDriveName: drive.name),
                    driveID: drive.id,
                    driveName: drive.name,
                    storageLocation: .externalVolume(
                        uuid: preparedVolumeUUID,
                        displayName: externalVolume.displayName
                    ),
                    createdAt: now,
                    updatedAt: now
                )
                try await self.domainStore.save(configuration)
                savedConfiguration = configuration
                try await self.domainRegistrar.addPreparedDomain(prepared)
                return configuration
            }

            domains = try await domainStore.allConfigurations()
            try await refreshDomainSystemStates()
            statusMessage = "Added \(configuration.driveName) to Files on \(externalVolume.displayName)."
            errorMessage = nil
        } catch {
            if let savedConfiguration {
                await rollbackFailedDomainAddition(savedConfiguration)
            }
            placementStatesByConfigurationIdentifier[configurationIdentifier] = nil
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not add the provider domain on an external drive.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not add the provider domain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func moveDomain(
        _ configuration: ProviderDomainConfiguration,
        toExternalVolume externalVolume: ProviderExternalVolume?
    ) async {
        let targetStorageLocation: ProviderDomainStorageLocation
        if let externalVolume {
            guard case .eligible = externalVolume.eligibility else {
                errorMessage = "Choose an eligible encrypted APFS drive."
                statusMessage = nil
                return
            }
            targetStorageLocation = .externalVolume(
                uuid: externalVolume.uuid,
                displayName: externalVolume.displayName
            )
        } else {
            targetStorageLocation = .onThisMac
        }

        guard targetStorageLocation != configuration.storageLocation else { return }
        guard canMutate(configuration),
              domainTransitionConfigurationIdentifiers.insert(configuration.configurationIdentifier).inserted
        else { return }
        placementStatesByConfigurationIdentifier[configuration.configurationIdentifier] = .moving
        defer { domainTransitionConfigurationIdentifiers.remove(configuration.configurationIdentifier) }

        do {
            if let externalVolume {
                try await externalVolumeSelector.withSecurityScopedAccess(to: externalVolume) { volumeURL in
                    try await self.performDomainMove(
                        configuration,
                        targetStorageLocation: targetStorageLocation,
                        targetVolumeURL: volumeURL
                    )
                }
            } else {
                try await performDomainMove(
                    configuration,
                    targetStorageLocation: targetStorageLocation,
                    targetVolumeURL: nil
                )
            }
        } catch {
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not change File Provider storage.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not change storage for \(configuration.driveName): \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func repairDomain(_ configuration: ProviderDomainConfiguration) async {
        guard domainTransitionConfigurationIdentifiers.insert(configuration.configurationIdentifier).inserted else {
            return
        }
        placementStatesByConfigurationIdentifier[configuration.configurationIdentifier] = .moving
        defer { domainTransitionConfigurationIdentifiers.remove(configuration.configurationIdentifier) }

        do {
            guard var journal = try await relocationJournalStore.journal(
                configurationIdentifier: configuration.configurationIdentifier
            ) else {
                if case .authenticationRequired = placementState(for: configuration) {
                    try await domainRegistrar.reconnectDomain(for: configuration)
                    try await refreshDomainSystemStates()
                    errorMessage = nil
                    return
                }

                let repairJournal = ProviderDomainRelocationJournal(
                    configurationIdentifier: configuration.configurationIdentifier,
                    sourceConfiguration: configuration,
                    targetStorageLocation: configuration.storageLocation,
                    knownFoldersWereActive: false,
                    phase: .needsRepair
                )
                try await relocationJournalStore.save(repairJournal)
                try await registerRepairTarget(from: repairJournal)
                statusMessage = "Repaired File Provider storage for \(configuration.driveName)."
                errorMessage = nil
                return
            }

            let registeredStates = try await domainRegistrar.registeredDomainStates()
            let registeredDomainIdentifiers = Set(registeredStates.map(\.domainIdentifier))
            let currentConfiguration = try await domainStore.configuration(
                configurationIdentifier: configuration.configurationIdentifier
            )

            if journal.phase == .knownFolderReclaimRequired {
                try await reclaimKnownFolders(for: configuration)
                try await relocationJournalStore.remove(
                    configurationIdentifier: configuration.configurationIdentifier
                )
                try await refreshDomainSystemStates()
                statusMessage = "Repaired Desktop and Documents for \(configuration.driveName)."
                errorMessage = nil
                return
            }


            if let currentConfiguration,
               currentConfiguration.domainIdentifier == journal.targetDomainIdentifier,
               registeredDomainIdentifiers.contains(currentConfiguration.domainIdentifier) {
                try await snapshotStore?.removeSnapshots(
                    domainIdentifier: journal.sourceConfiguration.domainIdentifier
                )
                try await eventStore?.removeEvents(
                    domainIdentifier: journal.sourceConfiguration.domainIdentifier
                )
                if journal.knownFoldersWereActive {
                    try await reclaimKnownFolders(for: currentConfiguration)
                }
                try await relocationJournalStore.remove(
                    configurationIdentifier: configuration.configurationIdentifier
                )
                domains = try await domainStore.allConfigurations()
                try await refreshDomainSystemStates()
                statusMessage = "Finished repairing \(configuration.driveName)."
                errorMessage = nil
                return
            }

            if let currentConfiguration,
               currentConfiguration.domainIdentifier == journal.sourceConfiguration.domainIdentifier,
               registeredDomainIdentifiers.contains(journal.sourceConfiguration.domainIdentifier) {
                if journal.knownFoldersWereActive {
                    try await refreshKnownFolderSyncStates()
                    if knownFolderSyncState(for: currentConfiguration) != .active {
                        try await reclaimKnownFolders(for: currentConfiguration)
                    }
                }
                try await relocationJournalStore.remove(
                    configurationIdentifier: configuration.configurationIdentifier
                )
                try await refreshDomainSystemStates()
                statusMessage = "Restored the original storage for \(configuration.driveName)."
                errorMessage = nil
                return
            }

            journal.phase = .needsRepair
            journal.updatedAt = Date()
            try await relocationJournalStore.save(journal)
            try await registerRepairTarget(from: journal)
            statusMessage = "Repaired File Provider storage for \(configuration.driveName)."
            errorMessage = nil
        } catch {
            placementStatesByConfigurationIdentifier[configuration.configurationIdentifier] = .needsRepair(
                error.localizedDescription
            )
            errorMessage = "Could not repair \(configuration.driveName): \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func removeDomain(_ configuration: ProviderDomainConfiguration) async {
        guard canMutate(configuration),
              domainTransitionConfigurationIdentifiers.insert(configuration.configurationIdentifier).inserted
        else { return }
        defer { domainTransitionConfigurationIdentifiers.remove(configuration.configurationIdentifier) }

        do {
            try await removeDomainAndLocalState(configuration)
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            try await refreshDomainSystemStates()
            statusMessage = "Removed \(configuration.displayName) from Files."
            errorMessage = nil
        } catch {
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not remove the provider domain.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not remove the provider domain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func enableKnownFolderSync(for configuration: ProviderDomainConfiguration) async {
        #if os(macOS)
        guard beginKnownFolderTransition(for: configuration) else { return }
        defer { domainTransitionConfigurationIdentifiers.remove(configuration.configurationIdentifier) }

        do {
            let token = try await usableToken(accountIdentifier: configuration.accountIdentifier)
            let remote = fileProviderFactory(token.accessToken)
            let parentFileID = try await KDrivePrivateDirectoryResolver.resolveFileID(
                driveID: configuration.driveID,
                rootFileID: configuration.rootFileID,
                remote: remote
            )
            try await domainRegistrar.claimKnownFolders(for: configuration, parentFileID: parentFileID)
            try await refreshKnownFolderSyncStates()
            statusMessage = "Desktop and Documents now sync with \(configuration.displayName) in kDrive /private."
            errorMessage = nil
        } catch {
            try? await refreshKnownFolderSyncStates()
            guard isUserCancellation(error) == false else { return }
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not enable Desktop and Documents synchronization.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not sync Desktop and Documents with kDrive /private: \(error.localizedDescription)"
            statusMessage = nil
        }
        #endif
    }

    func disableKnownFolderSync(for configuration: ProviderDomainConfiguration) async {
        #if os(macOS)
        guard beginKnownFolderTransition(for: configuration) else { return }
        defer { domainTransitionConfigurationIdentifiers.remove(configuration.configurationIdentifier) }

        do {
            try await domainRegistrar.releaseKnownFolders(for: configuration)
            try await refreshKnownFolderSyncStates()
            statusMessage = "Stopped syncing Desktop and Documents with \(configuration.displayName)."
            errorMessage = nil
        } catch {
            try? await refreshKnownFolderSyncStates()
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not stop Desktop and Documents synchronization.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not stop syncing Desktop and Documents: \(error.localizedDescription)"
            statusMessage = nil
        }
        #endif
    }

    func logoutAccount(_ account: ProviderAccount) async {
        let accountDomains = domains(for: account.accountIdentifier)
        guard let unavailableDomain = accountDomains.first(where: { canMutate($0) == false }) else {
            let identifiers = Set(accountDomains.map(\.configurationIdentifier))
            domainTransitionConfigurationIdentifiers.formUnion(identifiers)
            defer { domainTransitionConfigurationIdentifiers.subtract(identifiers) }
            await performLogout(account, domains: accountDomains)
            return
        }
        errorMessage = "Connect \(unavailableDomain.storageLocation.userFacingTitle) and finish or repair its File Provider operation before logging out."
        statusMessage = nil
    }

    private func performLogout(_ account: ProviderAccount, domains accountDomains: [ProviderDomainConfiguration]) async {
        do {
            for domain in accountDomains {
                try await removeDomainAndLocalState(domain)
            }

            try await tokenStore.deleteToken(accountIdentifier: account.accountIdentifier)
            try await accountStore.remove(accountIdentifier: account.accountIdentifier)
            drivesByAccountIdentifier[account.accountIdentifier] = nil
            selectedDriveIDs[account.accountIdentifier] = nil
            manualDriveIDs[account.accountIdentifier] = nil
            manualDriveNames[account.accountIdentifier] = nil
            automaticallyLoadedDriveAccountIdentifiers.remove(account.accountIdentifier)

            accounts = try await accountStore.allAccounts()
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            try await refreshDomainSystemStates()
            statusMessage = "Logged out \(account.displayName)."
            errorMessage = nil
        } catch {
            await recordAppFailure(
                kind: .authentication,
                summary: "Could not log out the account.",
                error: error,
                category: .authentication
            )
            errorMessage = "Could not log out \(account.displayName): \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func renameAccount(accountIdentifier: String, displayName: String) async {
        guard var account = account(accountIdentifier: accountIdentifier) else { return }
        guard account.updateDisplayName(displayName) else { return }

        do {
            try await accountStore.save(account)
            accounts = try await accountStore.allAccounts()
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            try await refreshDomainSystemStates()
            errorMessage = nil
        } catch {
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not rename the account.",
                error: error,
                category: .storage
            )
            errorMessage = "Could not rename the account: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    private func loadDrivesIfPossible(accountIdentifier: String) async {
        guard account(accountIdentifier: accountIdentifier) != nil,
              loadingDriveAccountIdentifiers.contains(accountIdentifier) == false,
              drivesByAccountIdentifier[accountIdentifier] == nil,
              automaticallyLoadedDriveAccountIdentifiers.contains(accountIdentifier) == false
        else {
            return
        }

        do {
            guard let token = try await tokenStore.loadToken(accountIdentifier: accountIdentifier) else {
                return
            }
            guard token.shouldRefresh() == false || token.refreshToken != nil else {
                return
            }

            automaticallyLoadedDriveAccountIdentifiers.insert(accountIdentifier)
            await loadDrives(accountIdentifier: accountIdentifier)
        } catch {
            automaticallyLoadedDriveAccountIdentifiers.insert(accountIdentifier)
            await recordAppFailure(
                kind: .driveDiscovery,
                summary: "Could not check saved account credentials.",
                error: error,
                category: .authentication
            )
            errorMessage = "Could not check saved account credentials: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    private func createAccount(authenticationKind: ProviderAccountAuthenticationKind, token: KDriveOAuthToken) async throws -> ProviderAccount {
        let now = Date()
        let account = ProviderAccount(
            displayName: nextAccountDisplayName(authenticationKind: authenticationKind, token: token),
            authenticationKind: authenticationKind,
            createdAt: now,
            updatedAt: now
        )

        try await tokenStore.saveToken(token, accountIdentifier: account.accountIdentifier)
        do {
            try await accountStore.save(account)
        } catch {
            try? await tokenStore.deleteToken(accountIdentifier: account.accountIdentifier)
            throw error
        }

        accounts = try await accountStore.allAccounts()
        seedDraftState(for: account.accountIdentifier)
        errorMessage = nil
        return account
    }

    private func nextAccountDisplayName(authenticationKind: ProviderAccountAuthenticationKind, token: KDriveOAuthToken) -> String {
        let baseName = idTokenDisplayName(from: token) ??
            (authenticationKind == .manualAccessToken ? "Manual Token" : "Infomaniak Account")
        return uniqueAccountDisplayName(baseName: baseName)
    }

    private func uniqueAccountDisplayName(baseName: String) -> String {
        let existingNames = Set(accounts.map(\.displayName))
        let normalizedBaseName = trimmed(baseName).nilIfEmpty ?? "Infomaniak Account"
        guard existingNames.contains(normalizedBaseName) else {
            return normalizedBaseName
        }

        var index = 2
        var candidate = "\(normalizedBaseName) \(index)"
        while existingNames.contains(candidate) {
            index += 1
            candidate = "\(normalizedBaseName) \(index)"
        }
        return candidate
    }

    private func idTokenDisplayName(from token: KDriveOAuthToken) -> String? {
        guard let idToken = token.idToken,
              let payloadData = jwtPayloadData(from: idToken),
              let claims = try? JSONDecoder().decode(OAuthIDTokenDisplayNameClaims.self, from: payloadData)
        else {
            return nil
        }

        let fullName = [claims.givenName, claims.familyName]
            .compactMap { trimmed($0 ?? "").nilIfEmpty }
            .joined(separator: " ")

        return [claims.name, fullName.nilIfEmpty]
            .compactMap { $0 }
            .compactMap { trimmed($0).nilIfEmpty }
            .first
    }

    private func jwtPayloadData(from token: String) -> Data? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }

        return Data(base64Encoded: payload)
    }

    private func performDomainMove(
        _ sourceConfiguration: ProviderDomainConfiguration,
        targetStorageLocation: ProviderDomainStorageLocation,
        targetVolumeURL: URL?
    ) async throws {
        try await refreshKnownFolderSyncStates()
        let knownFoldersWereActive: Bool
        switch knownFolderSyncState(for: sourceConfiguration) {
        case .active, .partial:
            knownFoldersWereActive = true
        case .inactive, .unavailable:
            knownFoldersWereActive = false
        }

        var journal = ProviderDomainRelocationJournal(
            configurationIdentifier: sourceConfiguration.configurationIdentifier,
            sourceConfiguration: sourceConfiguration,
            targetStorageLocation: targetStorageLocation,
            knownFoldersWereActive: knownFoldersWereActive
        )
        try await relocationJournalStore.save(journal)

        var sourceWasRemoved = false
        var targetWasRegistered = false
        do {
            try await domainRegistrar.waitForStabilization(for: sourceConfiguration)
            if knownFoldersWereActive {
                try await domainRegistrar.releaseKnownFolders(for: sourceConfiguration)
                journal.phase = .knownFoldersReleased
                journal.updatedAt = Date()
                try await relocationJournalStore.save(journal)
                try await domainRegistrar.waitForStabilization(for: sourceConfiguration)
            }

            let prepared = try prepareReplacementDomain(
                for: sourceConfiguration,
                targetStorageLocation: targetStorageLocation,
                targetVolumeURL: targetVolumeURL
            )
            journal.targetDomainIdentifier = prepared.domainIdentifier
            journal.updatedAt = Date()
            try await relocationJournalStore.save(journal)

            let preservedURL = try await domainRegistrar.removeDomainPreservingDirtyUserData(
                for: sourceConfiguration
            )
            sourceWasRemoved = true
            if let preservedURL {
                preservedDataLocation = ProviderPreservedDataLocation(
                    url: preservedURL,
                    driveName: sourceConfiguration.driveName
                )
            }
            journal.phase = .sourceRemoved
            journal.updatedAt = Date()
            try await relocationJournalStore.save(journal)

            var replacementConfiguration = sourceConfiguration
            replacementConfiguration.domainIdentifier = prepared.domainIdentifier
            replacementConfiguration.storageLocation = targetStorageLocation
            replacementConfiguration.updatedAt = Date()
            try await domainStore.save(replacementConfiguration)
            journal.phase = .targetConfigurationSaved
            journal.updatedAt = Date()
            try await relocationJournalStore.save(journal)

            try await domainRegistrar.addPreparedDomain(prepared)
            targetWasRegistered = true
            journal.phase = .targetRegistered
            journal.updatedAt = Date()
            try await relocationJournalStore.save(journal)

            domains = try await domainStore.allConfigurations()
            try await snapshotStore?.removeSnapshots(
                domainIdentifier: sourceConfiguration.domainIdentifier
            )
            try await eventStore?.removeEvents(
                domainIdentifier: sourceConfiguration.domainIdentifier
            )

            if knownFoldersWereActive {
                do {
                    try await reclaimKnownFolders(for: replacementConfiguration)
                } catch {
                    journal.phase = .knownFolderReclaimRequired
                    journal.updatedAt = Date()
                    try await relocationJournalStore.save(journal)
                    placementStatesByConfigurationIdentifier[sourceConfiguration.configurationIdentifier] = .needsRepair(
                        "Storage changed, but Desktop & Documents still need permission."
                    )
                    statusMessage = "Moved \(sourceConfiguration.driveName), but Desktop and Documents need repair."
                    errorMessage = nil
                    return
                }
            }

            try await relocationJournalStore.remove(
                configurationIdentifier: sourceConfiguration.configurationIdentifier
            )
            try await refreshDomainSystemStates()
            statusMessage = "Moved \(sourceConfiguration.driveName) to \(targetStorageLocation.userFacingTitle)."
            errorMessage = nil
        } catch {
            let registeredStatesAfterFailure = try? await domainRegistrar.registeredDomainStates()
            let targetIsInRegisteredStates = registeredStatesAfterFailure?.contains {
                $0.domainIdentifier == journal.targetDomainIdentifier
            } == true
            let targetAppearsRegistered = targetWasRegistered || targetIsInRegisteredStates
            if targetAppearsRegistered {
                journal.phase = .targetRegistered
                journal.updatedAt = Date()
                try? await relocationJournalStore.save(journal)
                placementStatesByConfigurationIdentifier[sourceConfiguration.configurationIdentifier] = .needsRepair(
                    "The new storage is registered, but cleanup still needs to finish."
                )
            } else if sourceWasRemoved {
                do {
                    try await recoverSourcePlacement(from: journal)
                } catch let recoveryError {
                    journal.phase = .needsRepair
                    journal.updatedAt = Date()
                    try? await relocationJournalStore.save(journal)
                    placementStatesByConfigurationIdentifier[sourceConfiguration.configurationIdentifier] = .needsRepair(
                        recoveryError.localizedDescription
                    )
                    throw PotassiumProviderAppModelError.storageMoveAndRecoveryFailed(
                        move: error.localizedDescription,
                        recovery: recoveryError.localizedDescription
                    )
                }
            } else {
                if knownFoldersWereActive, journal.phase == .knownFoldersReleased {
                    do {
                        try await reclaimKnownFolders(for: sourceConfiguration)
                    } catch {
                        journal.phase = .knownFolderReclaimRequired
                        journal.updatedAt = Date()
                        try? await relocationJournalStore.save(journal)
                        placementStatesByConfigurationIdentifier[sourceConfiguration.configurationIdentifier] = .needsRepair(
                            "Desktop & Documents need permission after the canceled storage change."
                        )
                        throw error
                    }
                }
                try? await relocationJournalStore.remove(
                    configurationIdentifier: sourceConfiguration.configurationIdentifier
                )
                try? await refreshDomainSystemStates()
            }
            throw error
        }
    }

    private func prepareReplacementDomain(
        for sourceConfiguration: ProviderDomainConfiguration,
        targetStorageLocation: ProviderDomainStorageLocation,
        targetVolumeURL: URL?
    ) throws -> ProviderPreparedDomain {
        let target: ProviderDomainPreparationTarget
        switch targetStorageLocation {
        case .onThisMac:
            target = .onThisMac
        case .externalVolume(let expectedVolumeUUID, _):
            guard let targetVolumeURL else {
                throw PotassiumProviderAppModelError.externalVolumeUnavailable
            }
            target = .externalVolume(targetVolumeURL)
            let prepared = try domainRegistrar.prepareDomain(
                configurationIdentifier: sourceConfiguration.configurationIdentifier,
                domainIdentifier: UUID().uuidString,
                displayName: sourceConfiguration.displayName,
                target: target
            )
            guard prepared.volumeUUID == expectedVolumeUUID else {
                throw PotassiumProviderAppModelError.externalVolumeIdentityMismatch
            }
            return prepared
        }

        return try domainRegistrar.prepareDomain(
            configurationIdentifier: sourceConfiguration.configurationIdentifier,
            domainIdentifier: UUID().uuidString,
            displayName: sourceConfiguration.displayName,
            target: target
        )
    }

    private func recoverSourcePlacement(
        from journal: ProviderDomainRelocationJournal
    ) async throws {
        let source = journal.sourceConfiguration
        let recovered: ProviderDomainConfiguration

        switch source.storageLocation {
        case .onThisMac:
            recovered = try await prepareSaveAndRegisterRecovery(
                source,
                targetStorageLocation: .onThisMac,
                volumeURL: nil
            )
        case .externalVolume(let volumeUUID, _):
            guard let mountedVolume = try externalVolumeSelector.mountedVolume(uuid: volumeUUID) else {
                throw PotassiumProviderAppModelError.externalVolumeUnavailable
            }
            recovered = try await externalVolumeSelector.withSecurityScopedAccess(to: mountedVolume) { volumeURL in
                try await self.prepareSaveAndRegisterRecovery(
                    source,
                    targetStorageLocation: source.storageLocation,
                    volumeURL: volumeURL
                )
            }
        }

        try await snapshotStore?.removeSnapshots(domainIdentifier: source.domainIdentifier)
        try await eventStore?.removeEvents(domainIdentifier: source.domainIdentifier)
        if journal.knownFoldersWereActive {
            try await reclaimKnownFolders(for: recovered)
        }
        try await relocationJournalStore.remove(
            configurationIdentifier: source.configurationIdentifier
        )
        domains = try await domainStore.allConfigurations()
        try await refreshDomainSystemStates()
    }

    private func prepareSaveAndRegisterRecovery(
        _ source: ProviderDomainConfiguration,
        targetStorageLocation: ProviderDomainStorageLocation,
        volumeURL: URL?
    ) async throws -> ProviderDomainConfiguration {
        let prepared = try prepareReplacementDomain(
            for: source,
            targetStorageLocation: targetStorageLocation,
            targetVolumeURL: volumeURL
        )
        var recovered = source
        recovered.domainIdentifier = prepared.domainIdentifier
        recovered.storageLocation = targetStorageLocation
        recovered.updatedAt = Date()
        try await domainStore.save(recovered)
        try await domainRegistrar.addPreparedDomain(prepared)
        return recovered
    }

    private func registerRepairTarget(
        from journal: ProviderDomainRelocationJournal
    ) async throws {
        let source = journal.sourceConfiguration
        let repaired: ProviderDomainConfiguration
        switch journal.targetStorageLocation {
        case .onThisMac:
            repaired = try await prepareSaveAndRegisterRecovery(
                source,
                targetStorageLocation: .onThisMac,
                volumeURL: nil
            )
        case .externalVolume(let volumeUUID, _):
            guard let mountedVolume = try externalVolumeSelector.mountedVolume(uuid: volumeUUID) else {
                throw PotassiumProviderAppModelError.externalVolumeUnavailable
            }
            repaired = try await externalVolumeSelector.withSecurityScopedAccess(to: mountedVolume) { volumeURL in
                try await self.prepareSaveAndRegisterRecovery(
                    source,
                    targetStorageLocation: journal.targetStorageLocation,
                    volumeURL: volumeURL
                )
            }
        }

        try await snapshotStore?.removeSnapshots(domainIdentifier: source.domainIdentifier)
        try await eventStore?.removeEvents(domainIdentifier: source.domainIdentifier)
        if journal.knownFoldersWereActive {
            do {
                try await reclaimKnownFolders(for: repaired)
            } catch {
                var reclaimJournal = journal
                reclaimJournal.phase = .knownFolderReclaimRequired
                reclaimJournal.updatedAt = Date()
                try await relocationJournalStore.save(reclaimJournal)
                domains = try await domainStore.allConfigurations()
                try await refreshDomainSystemStates()
                return
            }
        }
        try await relocationJournalStore.remove(configurationIdentifier: source.configurationIdentifier)
        domains = try await domainStore.allConfigurations()
        try await refreshDomainSystemStates()
    }

    private func reclaimKnownFolders(for configuration: ProviderDomainConfiguration) async throws {
        let token = try await usableToken(accountIdentifier: configuration.accountIdentifier)
        let parentFileID = try await KDrivePrivateDirectoryResolver.resolveFileID(
            driveID: configuration.driveID,
            rootFileID: configuration.rootFileID,
            remote: fileProviderFactory(token.accessToken)
        )
        try await domainRegistrar.claimKnownFolders(
            for: configuration,
            parentFileID: parentFileID
        )
    }

    private func removeDomainAndLocalState(_ configuration: ProviderDomainConfiguration) async throws {
        try await releaseKnownFoldersBeforeRemovingDomain(configuration)
        try await domainRegistrar.removeDomain(for: configuration)
        try await snapshotStore?.removeSnapshots(domainIdentifier: configuration.domainIdentifier)
        try await eventStore?.removeEvents(domainIdentifier: configuration.domainIdentifier)
        try await domainStore.remove(configurationIdentifier: configuration.configurationIdentifier)
        try await relocationJournalStore.remove(
            configurationIdentifier: configuration.configurationIdentifier
        )
        knownFolderSyncStatesByConfigurationIdentifier[configuration.configurationIdentifier] = nil
    }

    private func rollbackFailedDomainAddition(_ configuration: ProviderDomainConfiguration) async {
        try? await domainRegistrar.removeDomain(for: configuration)
        try? await snapshotStore?.removeSnapshots(domainIdentifier: configuration.domainIdentifier)
        try? await domainStore.remove(configurationIdentifier: configuration.configurationIdentifier)

        if let synchronizedState = try? await synchronizedDomainConfigurations() {
            domains = synchronizedState.configurations
        } else if let storedDomains = try? await domainStore.allConfigurations() {
            domains = storedDomains
        } else {
            domains.removeAll { $0.configurationIdentifier == configuration.configurationIdentifier }
        }
    }

    private func usableToken(accountIdentifier: String) async throws -> KDriveOAuthToken {
        guard account(accountIdentifier: accountIdentifier) != nil else {
            throw PotassiumProviderAppModelError.missingAccount
        }
        guard var token = try await tokenStore.loadToken(accountIdentifier: accountIdentifier) else {
            throw PotassiumProviderAppModelError.missingToken
        }

        if token.shouldRefresh() {
            guard let refreshToken = token.refreshToken else {
                throw PotassiumProviderAppModelError.expiredToken
            }
            token = try await KDriveOAuthClient.refresh(refreshToken: refreshToken)
            try await tokenStore.saveToken(token, accountIdentifier: accountIdentifier)
        }

        return token
    }

    private func beginKnownFolderTransition(for configuration: ProviderDomainConfiguration) -> Bool {
        domainTransitionConfigurationIdentifiers.insert(configuration.configurationIdentifier).inserted
    }

    private func refreshKnownFolderSyncStates() async throws {
        let systemStates = try await domainRegistrar.knownFolderSyncStates()
        knownFolderSyncStatesByConfigurationIdentifier = Dictionary(uniqueKeysWithValues: domains.map { configuration in
            (
                configuration.configurationIdentifier,
                systemStates[configuration.domainIdentifier] ?? .unavailable
            )
        })
    }

    private func refreshDomainSystemStates() async throws {
        try await refreshKnownFolderSyncStates()
        try await refreshPlacementStates()
    }

    private func refreshPlacementStates() async throws {
        let registeredStates = try await domainRegistrar.registeredDomainStates()
        let registeredByDomainIdentifier = Dictionary(
            uniqueKeysWithValues: registeredStates.map { ($0.domainIdentifier, $0) }
        )
        let journals = try await relocationJournalStore.allJournals()
        let journalsByConfigurationIdentifier = Dictionary(
            uniqueKeysWithValues: journals.map { ($0.configurationIdentifier, $0) }
        )

        var states: [String: ProviderDomainPlacementState] = [:]
        for configuration in domains {
            if let journal = journalsByConfigurationIdentifier[configuration.configurationIdentifier] {
                switch journal.phase {
                case .preparing, .knownFoldersReleased, .sourceRemoved,
                     .targetConfigurationSaved, .targetRegistered:
                    states[configuration.configurationIdentifier] = .needsRepair(
                        "A storage change was interrupted. Repair it before continuing."
                    )
                case .knownFolderReclaimRequired:
                    states[configuration.configurationIdentifier] = .needsRepair(
                        "Storage changed, but Desktop & Documents still need permission."
                    )
                case .needsRepair:
                    states[configuration.configurationIdentifier] = .needsRepair(
                        "File Provider could not finish the storage change."
                    )
                }
                continue
            }

            if let registeredState = registeredByDomainIdentifier[configuration.domainIdentifier] {
                if case .externalVolume(let volumeUUID, _) = configuration.storageLocation,
                   registeredState.configurationIdentifier != configuration.configurationIdentifier ||
                    registeredState.volumeUUID != volumeUUID {
                    states[configuration.configurationIdentifier] = .needsRepair(
                        "The registered external domain does not match this Mac's configuration."
                    )
                } else if registeredState.isDisconnected {
                    states[configuration.configurationIdentifier] = .authenticationRequired
                } else {
                    states[configuration.configurationIdentifier] = .connected
                }
                continue
            }

            switch configuration.storageLocation {
            case .onThisMac:
                #if os(macOS)
                states[configuration.configurationIdentifier] = .needsRepair(
                    "The File Provider domain is missing from this Mac."
                )
                #else
                // Other platforms do not expose registered-domain state.
                states[configuration.configurationIdentifier] = .connected
                #endif
            case .externalVolume(let volumeUUID, _):
                let mountedVolume = try externalVolumeSelector.mountedVolume(uuid: volumeUUID)
                states[configuration.configurationIdentifier] = mountedVolume == nil
                    ? .volumeUnavailable
                    : .needsRepair("The drive is connected, but its File Provider domain is missing.")
            }
        }
        placementStatesByConfigurationIdentifier = states
    }

    private func releaseKnownFoldersBeforeRemovingDomain(_ configuration: ProviderDomainConfiguration) async throws {
        #if os(macOS)
        try await refreshKnownFolderSyncStates()
        switch knownFolderSyncState(for: configuration) {
        case .active, .partial:
            try await domainRegistrar.releaseKnownFolders(for: configuration)
            try await refreshKnownFolderSyncStates()
        case .inactive, .unavailable:
            break
        }
        #endif
    }

    private func observeFileProviderDomainChanges() {
        #if os(macOS)
        fileProviderDomainChangeCancellable = NotificationCenter.default
            .publisher(for: .fileProviderDomainDidChange)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    try? await self?.refreshKnownFolderSyncStates()
                    try? await self?.refreshPlacementStates()
                }
            }
        #endif
    }

    private func isUserCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func refreshDraftFromSelectedDrive(accountIdentifier: String) {
        guard let selectedDriveID = selectedDriveIDs[accountIdentifier],
              let selectedDrive = drivesByAccountIdentifier[accountIdentifier]?.first(where: { $0.id == selectedDriveID })
        else {
            return
        }
        manualDriveIDs[accountIdentifier] = String(selectedDrive.id)
        manualDriveNames[accountIdentifier] = selectedDrive.name
    }

    private func resolvedDriveDraft(accountIdentifier: String) -> (id: Int, name: String)? {
        if let selectedDriveID = selectedDriveIDs[accountIdentifier],
           let selectedDrive = drivesByAccountIdentifier[accountIdentifier]?.first(where: { $0.id == selectedDriveID }) {
            return (selectedDrive.id, selectedDrive.name)
        }

        guard let id = Int(trimmed(manualDriveIDs[accountIdentifier] ?? "")), id > 0 else {
            return nil
        }
        let name = trimmed(manualDriveNames[accountIdentifier] ?? "").nilIfEmpty ?? "kDrive \(id)"
        return (id, name)
    }

    private static func makeDefaultAccountStore() -> any ProviderAccountStoring {
        if let appGroupStore = try? ProviderAccountFileStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier) {
            return appGroupStore
        }

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return ProviderAccountFileStore(
            directoryURL: applicationSupport
                .appendingPathComponent("potassiumProvider", isDirectory: true)
                .appendingPathComponent("Accounts", isDirectory: true)
        )
    }

    private static func makeDefaultDomainStore() -> any DomainConfigurationStoring {
        if let appGroupStore = try? DomainConfigurationFileStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier) {
            return appGroupStore
        }

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return DomainConfigurationFileStore(
            directoryURL: applicationSupport
                .appendingPathComponent("potassiumProvider", isDirectory: true)
                .appendingPathComponent("DomainConfigurations", isDirectory: true)
        )
    }

    private static func makeDefaultRelocationJournalStore() -> any ProviderDomainRelocationJournaling {
        if let appGroupStore = try? ProviderDomainRelocationFileStore(
            appGroupIdentifier: ProviderConstants.appGroupIdentifier
        ) {
            return appGroupStore
        }

        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return ProviderDomainRelocationFileStore(
            directoryURL: applicationSupport
                .appendingPathComponent("potassiumProvider", isDirectory: true)
                .appendingPathComponent("DomainRelocations", isDirectory: true)
        )
    }

    private static func makeDefaultSnapshotStore() -> (any KDriveSnapshotStoring)? {
        try? KDriveSnapshotSQLiteStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
    }

    private static func makeDefaultEventStore() -> (any KDriveProviderEventStoring)? {
        try? KDriveProviderEventSQLiteStore(appGroupIdentifier: ProviderConstants.appGroupIdentifier)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func migrateLegacyStateIfNeeded() async throws {
        let storedDomains = try await domainStore.allConfigurations()
        let legacyToken = try await tokenStore.loadLegacyToken()
        let needsLegacyAccount = legacyToken != nil ||
            storedDomains.contains { $0.accountIdentifier == ProviderConstants.legacyAccountIdentifier }

        guard needsLegacyAccount else { return }

        if try await accountStore.account(accountIdentifier: ProviderConstants.legacyAccountIdentifier) == nil {
            let now = Date()
            let authenticationKind: ProviderAccountAuthenticationKind = legacyToken?.refreshToken == nil ? .manualAccessToken : .oauth
            try await accountStore.save(ProviderAccount(
                accountIdentifier: ProviderConstants.legacyAccountIdentifier,
                displayName: "Legacy Account",
                authenticationKind: authenticationKind,
                createdAt: now,
                updatedAt: now
            ))
        }

        try await tokenStore.migrateLegacyToken(to: ProviderConstants.legacyAccountIdentifier)

        for configuration in storedDomains where configuration.accountIdentifier == ProviderConstants.legacyAccountIdentifier {
            try await domainStore.save(configuration)
        }
    }

    private func seedDraftState() {
        for account in accounts {
            seedDraftState(for: account.accountIdentifier)
        }
    }

    private func seedDraftState(for accountIdentifier: String) {
        if selectedDriveIDs[accountIdentifier] == nil {
            selectedDriveIDs[accountIdentifier] = drivesByAccountIdentifier[accountIdentifier]?.first?.id
        }
        if manualDriveIDs[accountIdentifier] == nil {
            manualDriveIDs[accountIdentifier] = ""
        }
        if manualDriveNames[accountIdentifier] == nil {
            manualDriveNames[accountIdentifier] = ""
        }
    }

    private func synchronizedDomainConfigurations() async throws -> (configurations: [ProviderDomainConfiguration], registrationError: Error?) {
        var configurations = try await domainStore.allConfigurations()
        let pendingRelocationConfigurationIdentifiers = Set(
            try await relocationJournalStore.allJournals().map(\.configurationIdentifier)
        )
        let accountLookup = Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountIdentifier, $0) })
        let displayNames = desiredDomainDisplayNames(for: configurations, accounts: accountLookup)
        var registrationError: Error?

        for index in configurations.indices {
            let desiredDisplayName = displayNames[configurations[index].configurationIdentifier] ?? configurations[index].displayName
            if configurations[index].displayName != desiredDisplayName {
                configurations[index].displayName = desiredDisplayName
                configurations[index].updatedAt = Date()
                try await domainStore.save(configurations[index])
            }

            if case .onThisMac = configurations[index].storageLocation,
               pendingRelocationConfigurationIdentifiers.contains(
                    configurations[index].configurationIdentifier
               ) == false {
                do {
                    try await domainRegistrar.addDomain(for: configurations[index])
                } catch {
                    registrationError = registrationError ?? error
                }
            }
        }

        return (
            configurations.sorted { lhs, rhs in
                lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            },
            registrationError
        )
    }

    private func desiredDomainDisplayNames(
        for configurations: [ProviderDomainConfiguration],
        accounts: [String: ProviderAccount]
    ) -> [String: String] {
        let baseNames = Dictionary(uniqueKeysWithValues: configurations.map {
            ($0.configurationIdentifier, ProviderDomainConfiguration.finderDisplayName(forDriveName: $0.driveName))
        })
        let groupedByBaseName = Dictionary(grouping: configurations) { configuration in
            baseNames[configuration.configurationIdentifier]?.localizedLowercase ?? configuration.driveName.localizedLowercase
        }

        var names: [String: String] = [:]
        for (_, group) in groupedByBaseName {
            if group.count == 1, let configuration = group.first {
                names[configuration.configurationIdentifier] = baseNames[configuration.configurationIdentifier]
                continue
            }

            for configuration in group {
                let baseName = baseNames[configuration.configurationIdentifier] ?? "kDrive"
                let accountName = accounts[configuration.accountIdentifier]?.displayName ?? "Account"
                names[configuration.configurationIdentifier] = "\(baseName) (\(accountName))"
            }
        }

        names = disambiguatedDisplayNames(names, configurations: configurations, suffix: { " - Drive \($0.driveID)" })
        names = disambiguatedDisplayNames(names, configurations: configurations, suffix: { " - \($0.domainIdentifier.prefix(8))" })
        return names
    }

    private func disambiguatedDisplayNames(
        _ names: [String: String],
        configurations: [ProviderDomainConfiguration],
        suffix: (ProviderDomainConfiguration) -> String
    ) -> [String: String] {
        let groupedNames = Dictionary(grouping: configurations) { configuration in
            names[configuration.configurationIdentifier] ?? configuration.displayName
        }
        var updatedNames = names

        for (_, group) in groupedNames where group.count > 1 {
            for configuration in group {
                let currentName = updatedNames[configuration.configurationIdentifier] ?? configuration.displayName
                updatedNames[configuration.configurationIdentifier] = currentName + suffix(configuration)
            }
        }

        return updatedNames
    }

    private func recordAppFailure(
        kind: KDriveProviderActivityKind,
        summary: String,
        error: Error,
        category: KDriveProviderActivityErrorCategory
    ) async {
        guard let eventStore else { return }

        do {
            try await eventStore.recordActivity(KDriveProviderActivityEvent(
                domainIdentifier: ProviderConstants.appActivityDomainIdentifier,
                driveID: 0,
                kind: kind,
                scope: .app,
                outcome: .failure,
                severity: .error,
                itemIdentifier: nil,
                itemName: nil,
                itemPath: nil,
                summary: summary,
                diagnostic: appDiagnostic(for: error, category: category),
                correlationID: UUID().uuidString
            ))
        } catch {
            Self.log.error("failed to save app failure activity event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appDiagnostic(
        for error: Error,
        category preferredCategory: KDriveProviderActivityErrorCategory
    ) -> KDriveProviderActivityErrorDiagnostic {
        let nsError = error as NSError
        let category = appErrorCategory(for: error, nsError: nsError, preferredCategory: preferredCategory)
        return KDriveProviderActivityErrorDiagnostic(
            errorCategory: category,
            underlyingErrorDomain: nsError.domain,
            underlyingErrorCode: nsError.code,
            recoverySuggestion: (error as? LocalizedError)?.recoverySuggestion,
            diagnosticSummary: appDiagnosticSummary(for: category)
        )
    }

    private func appErrorCategory(
        for error: Error,
        nsError: NSError,
        preferredCategory: KDriveProviderActivityErrorCategory
    ) -> KDriveProviderActivityErrorCategory {
        if error is KDriveOAuthError || error is KeychainTokenStoreError || error is PotassiumProviderAppModelError {
            return .authentication
        }
        if error is KDriveSnapshotStoreError {
            return .snapshot
        }
        if error is ProviderAccountStoreError || error is DomainConfigurationStoreError {
            return .storage
        }
        if nsError.domain == NSURLErrorDomain {
            return .network
        }
        if nsError.domain == NSCocoaErrorDomain {
            return .storage
        }
        return preferredCategory
    }

    private func appDiagnosticSummary(for category: KDriveProviderActivityErrorCategory) -> String {
        switch category {
        case .authentication:
            return "The app could not complete an authentication operation."
        case .network:
            return "The app could not reach the remote service."
        case .api:
            return "The remote API rejected an app request."
        case .fileProvider:
            return "The app could not complete File Provider domain management."
        case .listing:
            return "The app could not process a remote listing."
        case .snapshot:
            return "The app could not update local sync state."
        case .storage:
            return "The app could not read or write local state."
        case .validation:
            return "The app could not validate the requested operation."
        case .mutationConflict:
            return "The app detected a provider mutation conflict."
        case .unknown:
            return "The app encountered an unexpected error."
        }
    }
}

enum PotassiumProviderAppModelError: Error, Equatable, LocalizedError {
    case missingAccount
    case missingToken
    case expiredToken
    case externalVolumeUnavailable
    case externalVolumeIdentityMismatch
    case registeredTargetMissing
    case storageMoveAndRecoveryFailed(move: String, recovery: String)

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return "Choose an account before loading drives."
        case .missingToken:
            return "Connect to kDrive before loading drives."
        case .expiredToken:
            return "The saved access token has expired. Reconnect to kDrive."
        case .externalVolumeUnavailable:
            return "Connect the configured external drive and try again."
        case .externalVolumeIdentityMismatch:
            return "The selected drive changed while File Provider was preparing it."
        case .registeredTargetMissing:
            return "The replacement File Provider domain is no longer registered."
        case .storageMoveAndRecoveryFailed(let move, let recovery):
            return "The storage move failed (\(move)) and the original placement could not be recovered (\(recovery))."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct OAuthIDTokenDisplayNameClaims: Decodable {
    let name: String?
    let givenName: String?
    let familyName: String?

    enum CodingKeys: String, CodingKey {
        case name
        case givenName = "given_name"
        case familyName = "family_name"
    }
}
