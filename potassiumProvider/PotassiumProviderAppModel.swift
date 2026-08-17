import Combine
#if os(macOS)
import FileProvider
#endif
import Foundation
import OSLog
import PotassiumProviderCore
import Security

struct ProviderDriveKey: Hashable, Sendable {
    let accountIdentifier: String
    let driveID: Int
}

enum ProviderDriveAction: Equatable, Sendable {
    case addingToFiles
    case removingFromFiles
    case enablingKnownFolders
    case disablingKnownFolders
    case showingInFiles
    case syncingNow
}

private enum PendingEncryptedVaultActivation {
    case create(accountIdentifier: String, drive: KDriveDriveSummary)
    case recoveryKit(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        recoveryKitText: String
    )
    case iCloud(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        vaultID: VaultIdentifier
    )
}

@MainActor
final class PotassiumProviderAppModel: ObservableObject {
    private static let log = ProviderLog.app
    static let encryptedVaultRiskWarningDelaySeconds: TimeInterval = 5

    @Published private(set) var accounts: [ProviderAccount] = []
    @Published private(set) var drivesByAccountIdentifier: [String: [KDriveDriveSummary]] = [:]
    @Published private(set) var domains: [ProviderDomainConfiguration] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var loadingDriveAccountIdentifiers: Set<String> = []
    @Published private(set) var knownFolderSyncStatesByDomainIdentifier: [String: ProviderKnownFolderSyncState] = [:]
    @Published private(set) var knownFolderTransitionDomainIdentifiers: Set<String> = []
    @Published private(set) var activeDriveActions: [ProviderDriveKey: ProviderDriveAction] = [:]
    @Published private(set) var isReloadingStoredState = false
    @Published private(set) var pendingVaultProvisioning: PendingVaultProvisioning?
    @Published private(set) var vaultSetupStep: VaultSetupStep?
    @Published private(set) var vaultSetupOutcome = VaultSetupOutcome()
    @Published private(set) var cloudAccessCandidatesByDriveID:
        [Int: [VaultCloudAccessCandidate]] = [:]
    @Published private(set) var cloudAccessStatusesByVaultID:
        [VaultIdentifier: VaultCloudAccessStatus] = [:]
    @Published private(set) var localKeyStatusesByVaultID:
        [VaultIdentifier: VaultLocalKeyStatus] = [:]
    @Published private(set) var knownFolderPreflightsByDomainIdentifier:
        [String: KnownFolderPreflight] = [:]
    @Published private(set) var knownFolderTransferPhasesByDomainIdentifier:
        [String: KnownFolderTransferPhase] = [:]
    @Published private(set) var vaultUXPreferencesByVaultID:
        [VaultIdentifier: VaultUXPreferences] = [:]
    @Published private(set) var encryptedVaultsEnabled: Bool
    @Published private(set) var encryptedVaultICloudKeychainEnabled: Bool
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
    private let snapshotStore: (any KDriveSnapshotStoring)?
    private let eventStore: (any KDriveProviderEventStoring)?
    private let fileProviderFactory: (String) -> any KDriveFileProviding
    private let objectStoreFactory: (Int, String) -> any KDriveObjectStoreProviding
    private let vaultKeyStore: any VaultKeyStoring
    private let vaultDeviceIdentityStore: any VaultDeviceIdentityStoring
    private let vaultCloudAccessStore: any VaultCloudAccessStoring
    private let vaultUserPresenceAuthorizer: any VaultUserPresenceAuthorizing
    private let vaultUXDefaults: UserDefaults
    private let computerNameProvider: @Sendable () throws -> String
    private let currentUptime: () -> TimeInterval
    private var pendingVaultAccountIdentifier: String?
    private var pendingVaultDriveID: Int?
    private var pendingVaultDriveName: String?
    private var pendingVaultActivation: PendingEncryptedVaultActivation?
    private var vaultRiskWarningStartedAtUptime: TimeInterval?
    private var automaticallyLoadedDriveAccountIdentifiers: Set<String> = []
    private var fileProviderDomainChangeCancellable: AnyCancellable?

    init(
        accountStore: (any ProviderAccountStoring)? = nil,
        domainStore: (any DomainConfigurationStoring)? = nil,
        tokenStore: (any OAuthTokenStoring)? = nil,
        oauthAuthenticator: (any KDriveOAuthAuthenticating)? = nil,
        domainRegistrar: (any ProviderDomainRegistering)? = nil,
        snapshotStore: (any KDriveSnapshotStoring)? = nil,
        eventStore: (any KDriveProviderEventStoring)? = nil,
        automaticallyReloadStoredState: Bool = true,
        initialAccounts: [ProviderAccount] = [],
        initialDrivesByAccountIdentifier: [String: [KDriveDriveSummary]] = [:],
        initialDomains: [ProviderDomainConfiguration] = [],
        fileProviderFactory: @escaping (String) -> any KDriveFileProviding = { PotassiumKDriveService(bearerToken: $0) },
        objectStoreFactory: @escaping (Int, String) -> any KDriveObjectStoreProviding = {
            PotassiumKDriveObjectStore(driveID: $0, bearerToken: $1)
        },
        vaultKeyStore: (any VaultKeyStoring)? = nil,
        vaultDeviceIdentityStore: (any VaultDeviceIdentityStoring)? = nil,
        vaultCloudAccessStore: (any VaultCloudAccessStoring)? = nil,
        vaultUserPresenceAuthorizer: (any VaultUserPresenceAuthorizing)? = nil,
        vaultUXDefaults: UserDefaults? = nil,
        encryptedVaultsEnabled: Bool = UserDefaults.standard.bool(
            forKey: ProviderConstants.encryptedVaultFeatureFlag
        ),
        encryptedVaultICloudKeychainEnabled: Bool = UserDefaults.standard.bool(
            forKey: ProviderConstants.encryptedVaultICloudKeychainFeatureFlag
        ),
        computerNameProvider: @escaping @Sendable () throws -> String = { try KDriveMachineNamespaceName.current() },
        currentUptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.accountStore = accountStore ?? Self.makeDefaultAccountStore()
        self.domainStore = domainStore ?? Self.makeDefaultDomainStore()
        self.tokenStore = tokenStore ?? KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        self.oauthAuthenticator = oauthAuthenticator ?? KDriveOAuthWebAuthenticator()
        self.domainRegistrar = domainRegistrar ?? FileProviderDomainRegistrar()
        self.snapshotStore = snapshotStore ?? Self.makeDefaultSnapshotStore()
        self.eventStore = eventStore ?? Self.makeDefaultEventStore()
        self.fileProviderFactory = fileProviderFactory
        self.objectStoreFactory = objectStoreFactory
        let defaultVaultKeyStore = KeychainVaultKeyStore(
            accessGroup: ProviderConstants.keychainAccessGroup
        )
        self.vaultKeyStore = vaultKeyStore ?? defaultVaultKeyStore
        self.vaultDeviceIdentityStore = vaultDeviceIdentityStore
            ?? (vaultKeyStore as? any VaultDeviceIdentityStoring)
            ?? defaultVaultKeyStore
        self.vaultCloudAccessStore = vaultCloudAccessStore
            ?? KeychainVaultCloudAccessStore(
                accessGroup: ProviderConstants.keychainAccessGroup
            )
        self.vaultUserPresenceAuthorizer = vaultUserPresenceAuthorizer
            ?? LocalAuthenticationVaultUserPresenceAuthorizer()
        self.vaultUXDefaults = vaultUXDefaults
            ?? UserDefaults(
                suiteName: ProviderConstants.appGroupIdentifier
            )
            ?? .standard
        self.encryptedVaultsEnabled = encryptedVaultsEnabled
        self.encryptedVaultICloudKeychainEnabled =
            encryptedVaultICloudKeychainEnabled
        self.computerNameProvider = computerNameProvider
        self.currentUptime = currentUptime
        accounts = initialAccounts
        drivesByAccountIdentifier = initialDrivesByAccountIdentifier
        domains = initialDomains
        isReloadingStoredState = automaticallyReloadStoredState
        statusMessage = initialAccounts.isEmpty
            ? "No accounts connected."
            : "Loaded \(initialAccounts.count) account\(initialAccounts.count == 1 ? "" : "s")."
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

    func hasCompletedDriveDiscovery(for accountIdentifier: String) -> Bool {
        drivesByAccountIdentifier[accountIdentifier] != nil
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
        knownFolderSyncStatesByDomainIdentifier[configuration.domainIdentifier] ?? .unavailable
    }

    func knownFolderPreflight(
        for configuration: ProviderDomainConfiguration
    ) -> KnownFolderPreflight? {
        knownFolderPreflightsByDomainIdentifier[configuration.domainIdentifier]
    }

    func knownFolderTransferPhase(
        for configuration: ProviderDomainConfiguration
    ) -> KnownFolderTransferPhase {
        knownFolderTransferPhasesByDomainIdentifier[
            configuration.domainIdentifier
        ] ?? .idle
    }

    func cloudAccessCandidates(driveID: Int) -> [VaultCloudAccessCandidate] {
        cloudAccessCandidatesByDriveID[driveID] ?? []
    }

    func cloudAccessStatus(
        for configuration: ProviderDomainConfiguration
    ) -> VaultCloudAccessStatus {
        guard let vaultID = configuration.vault?.vaultIdentifier else {
            return .disabled
        }
        return cloudAccessStatusesByVaultID[vaultID] ?? .disabled
    }

    func vaultSetupNeedsAttention(
        for configuration: ProviderDomainConfiguration
    ) -> Bool {
        guard let vaultID = configuration.vault?.vaultIdentifier else {
            return false
        }
        return vaultUXPreferencesByVaultID[vaultID]?.onboardingVersion
            != VaultUXPreferences.currentOnboardingVersion
    }

    func localKeyStatus(
        for configuration: ProviderDomainConfiguration
    ) -> VaultLocalKeyStatus {
        guard let vaultID = configuration.vault?.vaultIdentifier else {
            return .missing
        }
        return localKeyStatusesByVaultID[vaultID] ?? .missing
    }

    func isChangingKnownFolderSync(for configuration: ProviderDomainConfiguration) -> Bool {
        knownFolderTransitionDomainIdentifiers.contains(configuration.domainIdentifier)
    }

    func knownFolderRemotePath(for configuration: ProviderDomainConfiguration) -> String {
        let state = knownFolderSyncState(for: configuration)
        if configuration.knownFolderLayout == .legacyPrivate, state != .inactive {
            return "/Private"
        }
        guard let namespaceName = try? computerNameProvider() else {
            return "/Private/<this Mac>"
        }
        return "/Private/\(namespaceName)"
    }

    func activeDriveAction(for key: ProviderDriveKey) -> ProviderDriveAction? {
        activeDriveActions[key]
    }

    func isPerformingDriveAction(for accountIdentifier: String) -> Bool {
        activeDriveActions.keys.contains { $0.accountIdentifier == accountIdentifier }
    }

    func isPerformingDomainAction(_ domainIdentifier: String) -> Bool {
        guard let configuration = domains.first(where: { $0.domainIdentifier == domainIdentifier }) else {
            return false
        }
        return activeDriveActions[driveKey(for: configuration)] != nil
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
        isReloadingStoredState = true
        defer { isReloadingStoredState = false }

        do {
            try await migrateLegacyStateIfNeeded()
            accounts = try await accountStore.allAccounts()
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            try await refreshKnownFolderSyncStates()
            await refreshVaultAccessState()
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

            let discoveredDrives = try await fileProviderFactory(token.accessToken).listDrives()
            let usableDrives = discoveredDrives.filter(\.isUsableInternalDrive)
            drivesByAccountIdentifier[accountIdentifier] = usableDrives
            await refreshVaultAccessState()
            if selectedDriveIDs[accountIdentifier] == nil ||
                usableDrives.contains(where: { $0.id == selectedDriveIDs[accountIdentifier] }) == false {
                selectedDriveIDs[accountIdentifier] = usableDrives.first?.id
            }
            refreshDraftFromSelectedDrive(accountIdentifier: accountIdentifier)
            statusMessage = usableDrives.isEmpty
                ? "No usable kDrives found for \(account.displayName)."
                : "Loaded \(usableDrives.count) usable kDrive\(usableDrives.count == 1 ? "" : "s") for \(account.displayName)."
        } catch {
            await recordAppFailure(
                kind: .driveDiscovery,
                summary: "Could not load kDrives.",
                error: error,
                category: .api
            )
            errorMessage = "Could not load kDrives. Refresh and try again."
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
        let key = ProviderDriveKey(accountIdentifier: accountIdentifier, driveID: draft.id)
        guard beginDriveAction(.addingToFiles, for: key) else { return }
        defer { endDriveAction(for: key) }

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
            try await refreshKnownFolderSyncStates()
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
            if FileProviderDomainRegistrationDiagnostics
                .applicationExtensionNotFoundError(in: error) != nil {
                errorMessage = FileProviderDomainRegistrationDiagnostics.userFacingMessage
            } else {
                errorMessage = "Could not add the provider domain: \(error.localizedDescription)"
            }
            statusMessage = nil
        }
    }

    func addDomain(accountIdentifier: String, drive: KDriveDriveSummary) async {
        guard canCreateDomain(for: drive) else { return }
        selectedDriveIDs[accountIdentifier] = drive.id
        manualDriveIDs[accountIdentifier] = String(drive.id)
        manualDriveNames[accountIdentifier] = drive.name
        await addDomain(accountIdentifier: accountIdentifier)
    }

    /// Begins encrypted-vault onboarding without creating remote objects. The
    /// unsupported-feature warning must remain visible for the configured delay
    /// before `acceptEncryptedVaultRiskAndPrepare` can prepare the vault.
    func prepareEncryptedVault(
        accountIdentifier: String,
        drive: KDriveDriveSummary
    ) async {
        guard canCreateDomain(for: drive) else { return }
        beginEncryptedVaultActivation(.create(
            accountIdentifier: accountIdentifier,
            drive: drive
        ))
    }

    func prepareOpenEncryptedVault(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        recoveryKitText: String
    ) {
        guard canCreateDomain(for: drive) else { return }
        beginEncryptedVaultActivation(.recoveryKit(
            accountIdentifier: accountIdentifier,
            drive: drive,
            recoveryKitText: recoveryKitText
        ))
    }

    func prepareOpenEncryptedVaultFromICloud(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        vaultID: VaultIdentifier
    ) {
        guard canCreateDomain(for: drive) else { return }
        guard encryptedVaultICloudKeychainEnabled else {
            errorMessage = "iCloud Keychain vault access is disabled until its security review is complete."
            return
        }
        beginEncryptedVaultActivation(.iCloud(
            accountIdentifier: accountIdentifier,
            drive: drive,
            vaultID: vaultID
        ))
    }

    private func beginEncryptedVaultActivation(
        _ activation: PendingEncryptedVaultActivation
    ) {
        guard encryptedVaultsEnabled else {
            errorMessage = "Encrypted vaults are disabled until the format passes the configured security-review gate."
            statusMessage = nil
            return
        }
        guard pendingVaultProvisioning == nil, vaultSetupStep == nil else {
            errorMessage = "Finish or cancel the current vault setup first."
            return
        }
        pendingVaultActivation = activation
        switch activation {
        case .create(let accountIdentifier, let drive),
             .recoveryKit(let accountIdentifier, let drive, _),
             .iCloud(let accountIdentifier, let drive, _):
            pendingVaultAccountIdentifier = accountIdentifier
            pendingVaultDriveID = drive.id
            pendingVaultDriveName = drive.name
        }
        vaultRiskWarningStartedAtUptime = currentUptime()
        vaultSetupStep = .unsupportedRiskWarning
        vaultSetupOutcome = VaultSetupOutcome()
        errorMessage = nil
        statusMessage = "Read and acknowledge the unsupported encrypted-vault data-loss warning."
    }

    /// Creates the randomized remote vault only after the mandatory warning
    /// delay. No domain is registered and no key is committed to the Keychain
    /// until `confirmEncryptedVault` succeeds.
    func acceptEncryptedVaultRiskAndPrepare() async {
        guard vaultSetupStep == .unsupportedRiskWarning,
              let warningStartedAt = vaultRiskWarningStartedAtUptime,
              currentUptime() - warningStartedAt
                >= Self.encryptedVaultRiskWarningDelaySeconds else {
            errorMessage = "Wait five seconds before continuing with this unsupported feature."
            return
        }
        guard let activation = pendingVaultActivation else {
            errorMessage = "There is no pending encrypted vault setup."
            return
        }
        vaultRiskWarningStartedAtUptime = nil
        switch activation {
        case .create(let accountIdentifier, let drive):
            await prepareNewEncryptedVaultAfterRiskAcceptance(
                accountIdentifier: accountIdentifier,
                drive: drive
            )
        case .recoveryKit(let accountIdentifier, let drive, let recoveryKitText):
            await openEncryptedVaultAfterRiskAcceptance(
                accountIdentifier: accountIdentifier,
                drive: drive,
                recoveryKitText: recoveryKitText
            )
        case .iCloud(let accountIdentifier, let drive, let vaultID):
            await openEncryptedVaultFromICloudAfterRiskAcceptance(
                accountIdentifier: accountIdentifier,
                drive: drive,
                vaultID: vaultID
            )
        }
    }

    private func prepareNewEncryptedVaultAfterRiskAcceptance(
        accountIdentifier: String,
        drive: KDriveDriveSummary
    ) async {
        let driveID = drive.id
        let key = ProviderDriveKey(accountIdentifier: accountIdentifier, driveID: driveID)
        guard beginDriveAction(.addingToFiles, for: key) else { return }
        defer { endDriveAction(for: key) }

        do {
            let token = try await usableToken(accountIdentifier: accountIdentifier)
            let service = VaultProvisioningService(
                objectStore: objectStoreFactory(driveID, token.accessToken),
                keyStore: vaultKeyStore
            )
            let pending = try await service.prepareNewVault(driveID: driveID)
            pendingVaultProvisioning = pending
            vaultSetupStep = .overview
            vaultSetupOutcome = VaultSetupOutcome()
            errorMessage = nil
            statusMessage = "Review encrypted-vault protection before saving the recovery kit."
        } catch {
            vaultSetupStep = .unsupportedRiskWarning
            vaultRiskWarningStartedAtUptime =
                currentUptime() - Self.encryptedVaultRiskWarningDelaySeconds
            errorMessage = "Could not prepare the encrypted vault: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func confirmEncryptedVault(
        recoveryKitConfirmation: String,
        useICloudKeychain: Bool = false
    ) async {
        guard let pending = pendingVaultProvisioning,
              let accountIdentifier = pendingVaultAccountIdentifier,
              let driveName = pendingVaultDriveName else {
            errorMessage = "There is no pending encrypted vault to confirm."
            return
        }
        let key = ProviderDriveKey(accountIdentifier: accountIdentifier, driveID: pending.driveID)
        guard beginDriveAction(.addingToFiles, for: key) else { return }
        defer { endDriveAction(for: key) }

        do {
            vaultSetupStep = .registering
            let token = try await usableToken(accountIdentifier: accountIdentifier)
            let service = VaultProvisioningService(
                objectStore: objectStoreFactory(pending.driveID, token.accessToken),
                keyStore: vaultKeyStore
            )
            let vaultConfiguration = try await service.confirm(
                pending,
                recoveryKitConfirmation: recoveryKitConfirmation
            )
            try await registerEncryptedDomain(
                accountIdentifier: accountIdentifier,
                driveID: pending.driveID,
                driveName: driveName,
                vaultConfiguration: vaultConfiguration
            )
            guard let configuration = domains.first(where: { configuration in
                configuration.vault?.vaultIdentifier == pending.vaultID
            }) else {
                throw VaultDomainRegistrationError.vaultAlreadyRegistered
            }
            var cloudStatus = VaultCloudAccessStatus.disabled
            if useICloudKeychain {
                guard encryptedVaultICloudKeychainEnabled else {
                    cloudStatus = .unavailable
                    vaultSetupOutcome = VaultSetupOutcome(
                        configuration: configuration,
                        cloudAccessStatus: cloudStatus,
                        recoveryKitVerified: true
                    )
                    clearPendingVault()
                    advanceVaultSetupAfterRegistration(
                        configuration: configuration
                    )
                    statusMessage = "Created the vault. iCloud Keychain convenience remains behind its security-review gate."
                    errorMessage = nil
                    return
                }
                do {
                    try await vaultCloudAccessStore.save(
                        VaultCloudAccessRecord(
                            configuration: vaultConfiguration,
                            driveID: pending.driveID,
                            rootKey: pending.rootKey
                        )
                    )
                    cloudStatus = .available
                } catch {
                    cloudStatus = .unavailable
                }
            }
            vaultSetupOutcome = VaultSetupOutcome(
                configuration: configuration,
                cloudAccessStatus: cloudStatus,
                recoveryKitVerified: true
            )
            clearPendingVault()
            await refreshVaultAccessState()
            advanceVaultSetupAfterRegistration(
                configuration: configuration
            )
            statusMessage = cloudStatus == .unavailable
                ? "Created the encrypted vault. iCloud Keychain setup needs attention."
                : "Created the encrypted vault and added it to Files."
            errorMessage = nil
        } catch {
            vaultSetupStep = .recoveryKit
            errorMessage = "Could not confirm the encrypted vault: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func cancelEncryptedVaultProvisioning() async {
        guard let pending = pendingVaultProvisioning,
              let accountIdentifier = pendingVaultAccountIdentifier else {
            finishVaultSetup()
            return
        }
        if let token = try? await usableToken(accountIdentifier: accountIdentifier) {
            let service = VaultProvisioningService(
                objectStore: objectStoreFactory(pending.driveID, token.accessToken),
                keyStore: vaultKeyStore
            )
            await service.cancel(pending)
        }
        clearPendingVault()
        vaultSetupStep = nil
        vaultSetupOutcome = VaultSetupOutcome()
        statusMessage = "Cancelled encrypted-vault setup."
    }

    func setVaultSetupStep(_ step: VaultSetupStep) {
        guard vaultSetupStep != nil else { return }
        vaultSetupStep = step
    }

    func finishVaultSetup() {
        if vaultSetupStep == .complete,
           let configuration = vaultSetupOutcome.configuration {
            saveVaultUXPreferences(
                VaultUXPreferences(
                    desktopDocumentsDeferred:
                        vaultSetupOutcome.desktopDocumentsDeferred
                ),
                configuration: configuration
            )
        }
        clearPendingVault()
        vaultSetupStep = nil
        vaultSetupOutcome = VaultSetupOutcome()
    }

    func resumeVaultSetup(for configuration: ProviderDomainConfiguration) {
        guard configuration.encryptionMode == .opaqueVaultV2,
              let vault = configuration.vault else {
            errorMessage = "The selected domain is not an encrypted vault."
            return
        }
        let preferences = vaultUXPreferencesByVaultID[vault.vaultIdentifier]
        let desktopDocumentsEnabled =
            knownFolderSyncState(for: configuration) == .active
        vaultSetupOutcome = VaultSetupOutcome(
            configuration: configuration,
            cloudAccessStatus:
                cloudAccessStatusesByVaultID[vault.vaultIdentifier]
                ?? .disabled,
            recoveryKitVerified: true,
            desktopDocumentsDeferred:
                preferences?.desktopDocumentsDeferred ?? false,
            desktopDocumentsEnabled: desktopDocumentsEnabled
        )
        #if os(macOS)
        vaultSetupStep = desktopDocumentsEnabled ? .complete : .desktopDocuments
        #else
        vaultSetupStep = .complete
        #endif
        errorMessage = nil
    }

    private func openEncryptedVaultAfterRiskAcceptance(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        recoveryKitText: String
    ) async {
        let key = ProviderDriveKey(accountIdentifier: accountIdentifier, driveID: drive.id)
        guard beginDriveAction(.addingToFiles, for: key) else { return }
        defer { endDriveAction(for: key) }

        do {
            let token = try await usableToken(accountIdentifier: accountIdentifier)
            let service = VaultProvisioningService(
                objectStore: objectStoreFactory(drive.id, token.accessToken),
                keyStore: vaultKeyStore
            )
            let vaultConfiguration = try await service.openExistingVault(
                recoveryKitText: recoveryKitText,
                expectedDriveID: drive.id
            )
            try await registerEncryptedDomain(
                accountIdentifier: accountIdentifier,
                driveID: drive.id,
                driveName: drive.name,
                vaultConfiguration: vaultConfiguration
            )
            await refreshVaultAccessState()
            vaultSetupOutcome = VaultSetupOutcome(
                configuration: domains.first(where: {
                    $0.vault?.vaultIdentifier == vaultConfiguration.vaultIdentifier
                }),
                cloudAccessStatus: .disabled,
                recoveryKitVerified: true
            )
            clearPendingVault()
            vaultSetupStep = .complete
            statusMessage = "Opened the encrypted vault on this device."
            errorMessage = nil
        } catch {
            vaultRiskWarningStartedAtUptime =
                currentUptime() - Self.encryptedVaultRiskWarningDelaySeconds
            errorMessage = "Could not open the encrypted vault: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    private func openEncryptedVaultFromICloudAfterRiskAcceptance(
        accountIdentifier: String,
        drive: KDriveDriveSummary,
        vaultID: VaultIdentifier
    ) async {
        let key = ProviderDriveKey(
            accountIdentifier: accountIdentifier,
            driveID: drive.id
        )
        guard beginDriveAction(.addingToFiles, for: key) else { return }
        defer { endDriveAction(for: key) }

        do {
            try await vaultUserPresenceAuthorizer.authorize(
                reason: "Open the encrypted kDrive vault on this device."
            )
            guard let record = try await vaultCloudAccessStore.record(
                vaultID: vaultID
            ) else {
                throw VaultCloudAccessStoreError.malformedRecord
            }
            let token = try await usableToken(accountIdentifier: accountIdentifier)
            let provisioning = VaultProvisioningService(
                objectStore: objectStoreFactory(drive.id, token.accessToken),
                keyStore: vaultKeyStore
            )
            let vaultConfiguration = try await provisioning.openExistingVault(
                cloudAccessRecord: record,
                expectedDriveID: drive.id
            )
            try await registerEncryptedDomain(
                accountIdentifier: accountIdentifier,
                driveID: drive.id,
                driveName: drive.name,
                vaultConfiguration: vaultConfiguration
            )
            await refreshVaultAccessState()
            vaultSetupOutcome = VaultSetupOutcome(
                configuration: domains.first(where: {
                    $0.vault?.vaultIdentifier == vaultConfiguration.vaultIdentifier
                }),
                cloudAccessStatus: .available,
                recoveryKitVerified: true
            )
            clearPendingVault()
            vaultSetupStep = .complete
            statusMessage = "Authenticated the iCloud Keychain record and opened the vault on this device."
            errorMessage = nil
        } catch {
            vaultRiskWarningStartedAtUptime =
                currentUptime() - Self.encryptedVaultRiskWarningDelaySeconds
            errorMessage = "Could not open the vault from iCloud Keychain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func enableICloudKeychainAccess(
        for configuration: ProviderDomainConfiguration
    ) async {
        guard encryptedVaultICloudKeychainEnabled else {
            errorMessage = "iCloud Keychain vault access is behind a separate security-review feature gate."
            return
        }
        guard let vault = configuration.vault else {
            errorMessage = "The selected domain is not an encrypted vault."
            return
        }
        do {
            try await vaultUserPresenceAuthorizer.authorize(
                reason: "Allow trusted Apple devices to open this encrypted vault."
            )
            guard let rootKey = try await vaultKeyStore.loadRootKey(
                vaultID: vault.vaultIdentifier
            ) else {
                throw EncryptedVaultError.missingKey
            }
            if let existing = try await vaultCloudAccessStore.record(
                vaultID: vault.vaultIdentifier
            ) {
                guard existing.keyEpoch <= vault.keyEpoch else {
                    throw VaultProvisioningError.keyEpochMismatch
                }
                if existing.keyEpoch == vault.keyEpoch,
                   existing.rootKey != rootKey {
                    throw VaultCloudAccessStoreError.conflictingRecord
                }
            }
            try await vaultCloudAccessStore.save(
                VaultCloudAccessRecord(
                    configuration: vault,
                    driveID: configuration.driveID,
                    rootKey: rootKey
                )
            )
            await refreshVaultAccessState()
            statusMessage = "Saved an end-to-end encrypted vault access record to iCloud Keychain. Other devices may take a moment to see it."
            errorMessage = nil
        } catch {
            await refreshVaultAccessState()
            errorMessage = "Could not enable iCloud Keychain access: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func removeICloudKeychainAccess(
        for configuration: ProviderDomainConfiguration
    ) async {
        guard let vaultID = configuration.vault?.vaultIdentifier else {
            errorMessage = "The selected domain is not an encrypted vault."
            return
        }
        do {
            try await vaultUserPresenceAuthorizer.authorize(
                reason: "Remove this vault access record from iCloud Keychain."
            )
            try await vaultCloudAccessStore.delete(vaultID: vaultID)
            await refreshVaultAccessState()
            statusMessage = "Removed the synchronized iCloud Keychain record. Device-local keys remain available and a full rekey is still required to revoke a lost device."
            errorMessage = nil
        } catch {
            errorMessage = "Could not remove iCloud Keychain access: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func restoreVaultKeyFromICloud(
        for configuration: ProviderDomainConfiguration
    ) async {
        guard let vault = configuration.vault else {
            errorMessage = "The selected domain is not an encrypted vault."
            return
        }
        do {
            try await vaultUserPresenceAuthorizer.authorize(
                reason: "Restore this vault key to the current device."
            )
            guard let record = try await vaultCloudAccessStore.record(
                vaultID: vault.vaultIdentifier
            ) else {
                throw VaultCloudAccessStoreError.malformedRecord
            }
            guard record.vaultConfiguration == vault,
                  record.driveID == configuration.driveID else {
                throw VaultProvisioningError.cloudRecordMismatch
            }
            let token = try await usableToken(
                accountIdentifier: configuration.accountIdentifier
            )
            let provisioning = VaultProvisioningService(
                objectStore: objectStoreFactory(
                    configuration.driveID,
                    token.accessToken
                ),
                keyStore: vaultKeyStore
            )
            _ = try await provisioning.openExistingVault(
                cloudAccessRecord: record,
                expectedDriveID: configuration.driveID
            )
            await refreshVaultAccessState()
            try? await domainRegistrar.signalWorkingSet(for: configuration)
            statusMessage = "Authenticated iCloud Keychain and restored the vault key to this device."
            errorMessage = nil
        } catch {
            await refreshVaultAccessState()
            errorMessage = "Could not restore the vault key from iCloud Keychain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func verifyRecoveryKit(
        for configuration: ProviderDomainConfiguration,
        recoveryKitText: String
    ) async {
        guard let vault = configuration.vault else {
            errorMessage = "The selected domain is not an encrypted vault."
            return
        }
        do {
            let token = try await usableToken(
                accountIdentifier: configuration.accountIdentifier
            )
            let provisioning = VaultProvisioningService(
                objectStore: objectStoreFactory(
                    configuration.driveID,
                    token.accessToken
                ),
                keyStore: vaultKeyStore
            )
            try await provisioning.verifyRecoveryKit(
                recoveryKitText,
                expectedConfiguration: vault,
                expectedDriveID: configuration.driveID
            )
            statusMessage = "The recovery kit authenticated this vault."
            errorMessage = nil
        } catch {
            errorMessage = "The recovery kit could not be verified: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    /// Normal logout and domain removal deliberately retain the device key.
    /// This separate destructive action requires the matching recovery kit and
    /// preserves the rollback checkpoint so a later import can still alarm.
    func forgetVaultKey(
        for configuration: ProviderDomainConfiguration,
        recoveryKitConfirmation: String
    ) async {
        guard let vault = configuration.vault else {
            errorMessage = "The selected domain is not an encrypted vault."
            return
        }
        do {
            let token = try await usableToken(
                accountIdentifier: configuration.accountIdentifier
            )
            let provisioning = VaultProvisioningService(
                objectStore: objectStoreFactory(
                    configuration.driveID,
                    token.accessToken
                ),
                keyStore: vaultKeyStore
            )
            try await provisioning.verifyRecoveryKit(
                recoveryKitConfirmation,
                expectedConfiguration: vault,
                expectedDriveID: configuration.driveID
            )
            try await vaultKeyStore.deleteRootKey(vaultID: vault.vaultIdentifier)
            await refreshVaultAccessState()
            statusMessage = cloudAccessStatusesByVaultID[vault.vaultIdentifier] == .available
                ? "Forgot this device-local key. Restore from iCloud Keychain or use the recovery kit to unlock it again."
                : "Forgot this vault key on this device. The recovery kit is required to unlock it again."
            errorMessage = nil
        } catch {
            errorMessage = "Could not forget the vault key: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func removeDomain(_ configuration: ProviderDomainConfiguration) async {
        let key = driveKey(for: configuration)
        guard beginDriveAction(.removingFromFiles, for: key) else { return }
        defer { endDriveAction(for: key) }

        do {
            try await removeDomainAndLocalState(configuration)
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            try await refreshKnownFolderSyncStates()
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

    func prepareKnownFolderSync(
        for configuration: ProviderDomainConfiguration
    ) async {
        #if os(macOS)
        knownFolderTransferPhasesByDomainIdentifier[
            configuration.domainIdentifier
        ] = .preparing
        do {
            let preflight = try await evaluateKnownFolderPreflight(
                for: configuration
            )
            knownFolderPreflightsByDomainIdentifier[
                configuration.domainIdentifier
            ] = preflight
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = preflight.canRequestClaim ? .idle : .attentionRequired
            errorMessage = nil
        } catch {
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = .attentionRequired
            errorMessage = "Could not prepare Desktop and Documents protection: \(error.localizedDescription)"
        }
        #endif
    }

    func enableKnownFolderSync(for configuration: ProviderDomainConfiguration) async {
        #if os(macOS)
        guard beginKnownFolderTransition(.enablingKnownFolders, for: configuration) else { return }
        defer { endKnownFolderTransition(for: configuration) }

        var namespacedConfiguration = configuration
        var didClaimKnownFolders = false
        var plaintextNamespaceName: String?
        do {
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = .preparing
            let preflight = try await evaluateKnownFolderPreflight(
                for: configuration
            )
            knownFolderPreflightsByDomainIdentifier[
                configuration.domainIdentifier
            ] = preflight
            guard preflight.canRequestClaim else {
                switch preflight.ownership {
                case .legacyPotassium:
                    throw KnownFolderSetupError.legacyMigrationRequired
                case .partial:
                    throw KnownFolderSetupError.partialClaimRequiresRepair
                case .thisVault:
                    try await refreshKnownFolderSyncStates()
                    knownFolderTransferPhasesByDomainIdentifier[
                        configuration.domainIdentifier
                    ] = .connectedUploading
                    return
                case .none, .externalProvider:
                    throw KnownFolderSetupError.preflightFailed
                }
            }
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = .awaitingConsent
            let token = try await usableToken(accountIdentifier: configuration.accountIdentifier)
            namespacedConfiguration.knownFolderLayout = .machineNamespace
            namespacedConfiguration.updatedAt = Date()
            try await domainStore.save(namespacedConfiguration)
            replaceDomainConfiguration(namespacedConfiguration)

            if configuration.encryptionMode == .opaqueVaultV2 {
                let vault = try await makeEncryptedVaultService(
                    configuration: namespacedConfiguration,
                    accessToken: token.accessToken
                )
                _ = try await vault.synchronize()
                let privateFolder = try await resolveOrCreateVaultFolder(
                    named: "Private",
                    parentID: nil,
                    vault: vault
                )
                let namespace = try await resolveOrCreateVaultFolder(
                    named: try computerNameProvider(),
                    parentID: privateFolder.id,
                    vault: vault
                )
                try await domainRegistrar.claimKnownFolders(
                    for: namespacedConfiguration,
                    parentItemIdentifier: namespace.id.fileProviderIdentifier
                )
            } else {
                let remote = fileProviderFactory(token.accessToken)
                let privateFileID = try await KDrivePrivateDirectoryResolver.resolveFileID(
                    driveID: configuration.driveID,
                    rootFileID: configuration.rootFileID,
                    remote: remote
                )
                let namespace = try await KDriveMachineNamespaceResolver.resolveOrCreate(
                    driveID: configuration.driveID,
                    privateDirectoryFileID: privateFileID,
                    computerName: try computerNameProvider(),
                    remote: remote
                )
                plaintextNamespaceName = namespace.name
                try await domainRegistrar.claimKnownFolders(
                    for: namespacedConfiguration,
                    parentFileID: namespace.fileID
                )
            }
            didClaimKnownFolders = true
            try await refreshKnownFolderSyncStates()
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = .connectedUploading
            if configuration.encryptionMode == .opaqueVaultV2 {
                statusMessage = "Desktop and Documents are connected to \(configuration.displayName). Finder shows initial encrypted-upload progress."
            } else {
                statusMessage = "Desktop and Documents now sync with \(configuration.displayName) in kDrive /Private/\(plaintextNamespaceName ?? "<this Mac>")."
            }
            errorMessage = nil
        } catch {
            if didClaimKnownFolders == false, namespacedConfiguration != configuration {
                do {
                    try await domainStore.save(configuration)
                    replaceDomainConfiguration(configuration)
                } catch {
                    Self.log.error("failed to restore known-folder layout for domain(\(configuration.domainIdentifier, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                }
            }
            try? await refreshKnownFolderSyncStates()
            guard isUserCancellation(error) == false else {
                knownFolderTransferPhasesByDomainIdentifier[
                    configuration.domainIdentifier
                ] = .idle
                return
            }
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = error.localizedDescription.localizedCaseInsensitiveContains(
                "quota"
            ) ? .quotaBlocked : .attentionRequired
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not enable Desktop and Documents synchronization.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not sync Desktop and Documents with this Mac's kDrive namespace: \(error.localizedDescription)"
            statusMessage = nil
        }
        #endif
    }

    func disableKnownFolderSync(for configuration: ProviderDomainConfiguration) async {
        #if os(macOS)
        guard beginKnownFolderTransition(.disablingKnownFolders, for: configuration) else { return }
        defer { endKnownFolderTransition(for: configuration) }

        do {
            try await domainRegistrar.releaseKnownFolders(for: configuration)
            try await refreshKnownFolderSyncStates()
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = .idle
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
            knownFolderTransferPhasesByDomainIdentifier[
                configuration.domainIdentifier
            ] = .attentionRequired
        }
        #endif
    }

    func configureDesktopDocumentsDuringSetup(enable: Bool) async {
        guard let configuration = vaultSetupOutcome.configuration else {
            errorMessage = "The encrypted vault has not been registered."
            return
        }
        guard enable else {
            vaultSetupOutcome.desktopDocumentsDeferred = true
            saveVaultUXPreferences(
                VaultUXPreferences(desktopDocumentsDeferred: true),
                configuration: configuration
            )
            vaultSetupStep = .complete
            return
        }

        await enableKnownFolderSync(for: configuration)
        if knownFolderSyncState(for: configuration) == .active {
            vaultSetupOutcome.desktopDocumentsEnabled = true
            saveVaultUXPreferences(
                VaultUXPreferences(desktopDocumentsDeferred: false),
                configuration: configuration
            )
            vaultSetupStep = .complete
        }
    }

    func userVisibleRootURL(for configuration: ProviderDomainConfiguration) async -> URL? {
        guard configuration.encryptionMode != .opaqueVaultV1 else {
            errorMessage = KnownFolderSetupError.unsupportedEncryptedVaultFormat
                .localizedDescription
            statusMessage = nil
            return nil
        }
        let key = driveKey(for: configuration)
        guard beginDriveAction(.showingInFiles, for: key) else { return nil }
        defer { endDriveAction(for: key) }

        do {
            let url = try await domainRegistrar.userVisibleRootURL(for: configuration)
            errorMessage = nil
            return url
        } catch {
            await recordAppFailure(
                kind: .domainManagement,
                summary: "Could not show the File Provider domain.",
                error: error,
                category: .fileProvider
            )
            #if os(macOS)
            errorMessage = "Could not show \(configuration.displayName) in Finder: \(error.localizedDescription)"
            #else
            errorMessage = "Could not show \(configuration.displayName) in Files: \(error.localizedDescription)"
            #endif
            statusMessage = nil
            return nil
        }
    }

    func syncNow(_ configuration: ProviderDomainConfiguration) async {
        guard configuration.encryptionMode != .opaqueVaultV1 else {
            errorMessage = KnownFolderSetupError.unsupportedEncryptedVaultFormat
                .localizedDescription
            statusMessage = nil
            return
        }
        let key = driveKey(for: configuration)
        guard beginDriveAction(.syncingNow, for: key) else { return }
        defer { endDriveAction(for: key) }

        do {
            try await domainRegistrar.signalWorkingSet(for: configuration)
            if knownFolderSyncState(for: configuration) == .active {
                knownFolderTransferPhasesByDomainIdentifier[
                    configuration.domainIdentifier
                ] = .upToDate
            }
            statusMessage = "Requested a fresh sync for \(configuration.displayName)."
            errorMessage = nil
        } catch {
            await recordAppFailure(
                kind: .changeSync,
                summary: "Could not request a fresh provider sync.",
                error: error,
                category: .fileProvider
            )
            errorMessage = "Could not sync \(configuration.displayName): \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func logoutAccount(_ account: ProviderAccount) async {
        guard isPerformingDriveAction(for: account.accountIdentifier) == false else {
            errorMessage = "Wait for the current drive action to finish before logging out \(account.displayName)."
            statusMessage = nil
            return
        }

        do {
            let accountDomains = domains(for: account.accountIdentifier)
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
            try await refreshKnownFolderSyncStates()
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
            try await refreshKnownFolderSyncStates()
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

    private func registerEncryptedDomain(
        accountIdentifier: String,
        driveID: Int,
        driveName: String,
        vaultConfiguration: ProviderVaultConfiguration
    ) async throws {
        guard domains.contains(where: {
            $0.vault?.vaultIdentifier == vaultConfiguration.vaultIdentifier
        }) == false else {
            throw VaultDomainRegistrationError.vaultAlreadyRegistered
        }

        let now = Date()
        let configuration = ProviderDomainConfiguration(
            accountIdentifier: accountIdentifier,
            displayName: "\(ProviderDomainConfiguration.finderDisplayName(forDriveName: driveName)) — Encrypted",
            driveID: driveID,
            driveName: driveName,
            knownFolderLayout: .machineNamespace,
            encryptionMode: .opaqueVaultV2,
            vault: vaultConfiguration,
            createdAt: now,
            updatedAt: now
        )

        try await domainStore.save(configuration)
        do {
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            if let registrationError = synchronizedState.registrationError {
                throw registrationError
            }
            try await refreshKnownFolderSyncStates()
        } catch {
            await rollbackFailedDomainAddition(configuration)
            throw error
        }
    }

    private func makeEncryptedVaultService(
        configuration: ProviderDomainConfiguration,
        accessToken: String
    ) async throws -> any EncryptedVaultProviding {
        guard let vaultConfiguration = configuration.vault,
              let rootKey = try await vaultKeyStore.loadRootKey(
                vaultID: vaultConfiguration.vaultIdentifier
              ) else {
            throw EncryptedVaultError.missingKey
        }
        let deviceID = try await vaultDeviceIdentityStore.loadOrCreateDeviceID(
            vaultID: vaultConfiguration.vaultIdentifier
        )
        let localStore = try VaultSQLiteStore(
            appGroupIdentifier: ProviderConstants.appGroupIdentifier,
            domainIdentifier: configuration.domainIdentifier,
            vaultID: vaultConfiguration.vaultIdentifier,
            rootKey: rootKey,
            keyEpoch: vaultConfiguration.keyEpoch
        )
        return try EncryptedVaultService(
            configuration: configuration,
            rootKey: rootKey,
            deviceID: deviceID,
            objectStore: objectStoreFactory(configuration.driveID, accessToken),
            localStore: localStore,
            keyStore: vaultKeyStore
        )
    }

    private func resolveOrCreateVaultFolder(
        named filename: String,
        parentID: VaultItemIdentifier?,
        vault: any EncryptedVaultProviding
    ) async throws -> VaultItem {
        var cursor: String?
        repeat {
            let page = try await vault.children(
                of: parentID,
                trashed: false,
                cursor: cursor,
                limit: 200
            )
            if let item = page.items.first(where: {
                $0.isDirectory && $0.filename == filename
            }) {
                return item
            }
            cursor = page.nextCursor
        } while cursor != nil
        return try await vault.createDirectory(
            parentID: parentID,
            filename: filename,
            createdAt: Date()
        )
    }

    private func clearPendingVault() {
        pendingVaultProvisioning = nil
        pendingVaultAccountIdentifier = nil
        pendingVaultDriveID = nil
        pendingVaultDriveName = nil
        pendingVaultActivation = nil
        vaultRiskWarningStartedAtUptime = nil
    }

    private func advanceVaultSetupAfterRegistration(
        configuration: ProviderDomainConfiguration
    ) {
        #if os(macOS)
        vaultSetupStep = .desktopDocuments
        #else
        saveVaultUXPreferences(
            VaultUXPreferences(desktopDocumentsDeferred: false),
            configuration: configuration
        )
        vaultSetupStep = .complete
        #endif
    }

    private func saveVaultUXPreferences(
        _ preferences: VaultUXPreferences,
        configuration: ProviderDomainConfiguration
    ) {
        guard let vaultID = configuration.vault?.vaultIdentifier,
              let data = try? JSONEncoder().encode(preferences) else {
            return
        }
        vaultUXDefaults.set(
            data,
            forKey: "vaultUX:\(vaultID.rawValue.uuidString.lowercased())"
        )
        vaultUXPreferencesByVaultID[vaultID] = preferences
    }

    private func evaluateKnownFolderPreflight(
        for configuration: ProviderDomainConfiguration
    ) async throws -> KnownFolderPreflight {
        guard configuration.encryptionMode != .opaqueVaultV1 else {
            throw KnownFolderSetupError.unsupportedEncryptedVaultFormat
        }
        let owner = try await domainRegistrar.knownFolderOwner()
        let ownership: KnownFolderPreflight.Ownership
        if let owner {
            if owner.isPartial {
                ownership = .partial(displayName: owner.displayName)
            } else if owner.domainIdentifier == configuration.domainIdentifier {
                ownership = .thisVault
            } else if let ownerConfiguration = domains.first(where: {
                $0.domainIdentifier == owner.domainIdentifier
            }), ownerConfiguration.encryptionMode == .legacyPlaintext {
                ownership = .legacyPotassium(
                    domainIdentifier: ownerConfiguration.domainIdentifier
                )
            } else {
                ownership = .externalProvider(displayName: owner.displayName)
            }
        } else {
            ownership = .none
        }

        let vaultIsUnlocked: Bool
        let remoteIsReachable: Bool
        if configuration.encryptionMode == .opaqueVaultV2,
           let vaultID = configuration.vault?.vaultIdentifier {
            let rootKey = try await vaultKeyStore.loadRootKey(vaultID: vaultID)
            vaultIsUnlocked = rootKey != nil
            if rootKey != nil {
                do {
                    let token = try await usableToken(
                        accountIdentifier: configuration.accountIdentifier
                    )
                    let vault = try await makeEncryptedVaultService(
                        configuration: configuration,
                        accessToken: token.accessToken
                    )
                    _ = try await vault.synchronize()
                    remoteIsReachable = true
                } catch {
                    remoteIsReachable = false
                }
            } else {
                remoteIsReachable = false
            }
        } else {
            vaultIsUnlocked = true
            do {
                _ = try await usableToken(
                    accountIdentifier: configuration.accountIdentifier
                )
                remoteIsReachable = true
            } catch {
                remoteIsReachable = false
            }
        }

        return KnownFolderPreflight(
            ownership: ownership,
            vaultIsUnlocked: vaultIsUnlocked,
            remoteIsReachable: remoteIsReachable,
            availableQuotaBytes: nil
        )
    }

    func refreshVaultAccessState() async {
        vaultUXPreferencesByVaultID = Dictionary(
            uniqueKeysWithValues: domains.compactMap { configuration in
                guard let vaultID = configuration.vault?.vaultIdentifier,
                      let data = vaultUXDefaults.data(
                        forKey:
                            "vaultUX:\(vaultID.rawValue.uuidString.lowercased())"
                      ),
                      let preferences = try? JSONDecoder().decode(
                        VaultUXPreferences.self,
                        from: data
                      ) else {
                    return nil
                }
                return (vaultID, preferences)
            }
        )

        var localStatuses: [VaultIdentifier: VaultLocalKeyStatus] = [:]
        for configuration in domains where configuration.encryptionMode == .opaqueVaultV2 {
            guard let vaultID = configuration.vault?.vaultIdentifier else {
                continue
            }
            do {
                localStatuses[vaultID] = try await vaultKeyStore.loadRootKey(
                    vaultID: vaultID
                ) == nil ? .missing : .available
            } catch VaultKeyStoreError.unhandledStatus(let status)
                where status == errSecInteractionNotAllowed {
                localStatuses[vaultID] = .locked
            } catch VaultCryptoError.invalidKeyLength {
                localStatuses[vaultID] = .invalid
            } catch {
                localStatuses[vaultID] = .invalid
            }
        }
        localKeyStatusesByVaultID = localStatuses

        guard encryptedVaultICloudKeychainEnabled else {
            cloudAccessCandidatesByDriveID = [:]
            cloudAccessStatusesByVaultID = Dictionary(
                uniqueKeysWithValues: localStatuses.keys.map { ($0, .disabled) }
            )
            return
        }

        do {
            let records = try await vaultCloudAccessStore.records()
            let groupedByVault = Dictionary(grouping: records, by: \.vaultID)
            cloudAccessCandidatesByDriveID = Dictionary(
                grouping: records.map(VaultCloudAccessCandidate.init),
                by: \.driveID
            ).mapValues {
                $0.sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt {
                        return lhs.createdAt < rhs.createdAt
                    }
                    return lhs.vaultID.rawValue.uuidString
                        < rhs.vaultID.rawValue.uuidString
                }
            }

            var statuses: [VaultIdentifier: VaultCloudAccessStatus] = [:]
            for configuration in domains where configuration.encryptionMode == .opaqueVaultV2 {
                guard let vault = configuration.vault else { continue }
                let matching = groupedByVault[vault.vaultIdentifier] ?? []
                guard matching.count <= 1 else {
                    statuses[vault.vaultIdentifier] = .conflict
                    continue
                }
                guard let record = matching.first else {
                    statuses[vault.vaultIdentifier] = .disabled
                    continue
                }
                if record.keyEpoch != vault.keyEpoch {
                    statuses[vault.vaultIdentifier] = .staleEpoch
                } else if record.driveID != configuration.driveID
                    || record.vaultConfiguration != vault {
                    statuses[vault.vaultIdentifier] = .conflict
                } else {
                    let localKey = try? await vaultKeyStore.loadRootKey(
                        vaultID: vault.vaultIdentifier
                    )
                    statuses[vault.vaultIdentifier] =
                        localKey != nil && localKey != record.rootKey
                        ? .conflict
                        : .available
                }
            }
            cloudAccessStatusesByVaultID = statuses
        } catch {
            cloudAccessCandidatesByDriveID = [:]
            cloudAccessStatusesByVaultID = Dictionary(
                uniqueKeysWithValues: localStatuses.keys.map { ($0, .unavailable) }
            )
        }
    }

    private func removeDomainAndLocalState(_ configuration: ProviderDomainConfiguration) async throws {
        try await releaseKnownFoldersBeforeRemovingDomain(configuration)
        try await domainRegistrar.removeDomain(for: configuration)
        try await snapshotStore?.removeSnapshots(domainIdentifier: configuration.domainIdentifier)
        try await eventStore?.removeEvents(domainIdentifier: configuration.domainIdentifier)
        try await domainStore.remove(domainIdentifier: configuration.domainIdentifier)
        knownFolderSyncStatesByDomainIdentifier[configuration.domainIdentifier] = nil
    }

    private func rollbackFailedDomainAddition(_ configuration: ProviderDomainConfiguration) async {
        try? await snapshotStore?.removeSnapshots(domainIdentifier: configuration.domainIdentifier)
        try? await domainStore.remove(domainIdentifier: configuration.domainIdentifier)

        if let synchronizedState = try? await synchronizedDomainConfigurations() {
            domains = synchronizedState.configurations
        } else if let storedDomains = try? await domainStore.allConfigurations() {
            domains = storedDomains
        } else {
            domains.removeAll { $0.domainIdentifier == configuration.domainIdentifier }
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

    private func driveKey(for configuration: ProviderDomainConfiguration) -> ProviderDriveKey {
        ProviderDriveKey(
            accountIdentifier: configuration.accountIdentifier,
            driveID: configuration.driveID
        )
    }

    private func beginDriveAction(_ action: ProviderDriveAction, for key: ProviderDriveKey) -> Bool {
        guard activeDriveActions[key] == nil else { return false }
        activeDriveActions[key] = action
        return true
    }

    private func endDriveAction(for key: ProviderDriveKey) {
        activeDriveActions[key] = nil
    }

    private func beginKnownFolderTransition(
        _ action: ProviderDriveAction,
        for configuration: ProviderDomainConfiguration
    ) -> Bool {
        let key = driveKey(for: configuration)
        guard beginDriveAction(action, for: key) else { return false }
        knownFolderTransitionDomainIdentifiers.insert(configuration.domainIdentifier)
        return true
    }

    private func endKnownFolderTransition(for configuration: ProviderDomainConfiguration) {
        knownFolderTransitionDomainIdentifiers.remove(configuration.domainIdentifier)
        endDriveAction(for: driveKey(for: configuration))
    }

    private func replaceDomainConfiguration(_ configuration: ProviderDomainConfiguration) {
        guard let index = domains.firstIndex(where: {
            $0.domainIdentifier == configuration.domainIdentifier
        }) else {
            return
        }
        domains[index] = configuration
    }

    private func refreshKnownFolderSyncStates() async throws {
        let systemStates = try await domainRegistrar.knownFolderSyncStates()
        knownFolderSyncStatesByDomainIdentifier = Dictionary(uniqueKeysWithValues: domains.map { configuration in
            (
                configuration.domainIdentifier,
                systemStates[configuration.domainIdentifier] ?? .unavailable
            )
        })
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
            manualDriveIDs[accountIdentifier] = ""
            manualDriveNames[accountIdentifier] = ""
            return
        }
        manualDriveIDs[accountIdentifier] = String(selectedDrive.id)
        manualDriveNames[accountIdentifier] = selectedDrive.name
    }

    private func canCreateDomain(for drive: KDriveDriveSummary) -> Bool {
        guard drive.isUsableInternalDrive else {
            errorMessage = "Only usable internal kDrives can be added to Files."
            statusMessage = nil
            return false
        }
        return true
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
        let accountLookup = Dictionary(uniqueKeysWithValues: accounts.map { ($0.accountIdentifier, $0) })
        let displayNames = desiredDomainDisplayNames(for: configurations, accounts: accountLookup)
        var registrationError: Error?

        for index in configurations.indices {
            let desiredDisplayName = displayNames[configurations[index].domainIdentifier] ?? configurations[index].displayName
            if configurations[index].displayName != desiredDisplayName {
                configurations[index].displayName = desiredDisplayName
                configurations[index].updatedAt = Date()
                try await domainStore.save(configurations[index])
            }

            // Preserve the saved record so the user can explicitly remove it,
            // but never re-register an incompatible v1 domain with File
            // Provider. An already registered system domain remains inert
            // because every extension runtime load also fails closed.
            guard configurations[index].encryptionMode != .opaqueVaultV1 else {
                continue
            }

            do {
                try await domainRegistrar.addDomain(for: configurations[index])
            } catch {
                registrationError = registrationError ?? error
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
            let driveName = ProviderDomainConfiguration.finderDisplayName(forDriveName: $0.driveName)
            let displayName = $0.encryptionMode == .opaqueVaultV2
                ? "\(driveName) — Encrypted"
                : driveName
            return ($0.domainIdentifier, displayName)
        })
        let groupedByBaseName = Dictionary(grouping: configurations) { configuration in
            baseNames[configuration.domainIdentifier]?.localizedLowercase ?? configuration.driveName.localizedLowercase
        }

        var names: [String: String] = [:]
        for (_, group) in groupedByBaseName {
            if group.count == 1, let configuration = group.first {
                names[configuration.domainIdentifier] = baseNames[configuration.domainIdentifier]
                continue
            }

            for configuration in group {
                let baseName = baseNames[configuration.domainIdentifier] ?? "kDrive"
                let accountName = accounts[configuration.accountIdentifier]?.displayName ?? "Account"
                names[configuration.domainIdentifier] = "\(baseName) (\(accountName))"
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
            names[configuration.domainIdentifier] ?? configuration.displayName
        }
        var updatedNames = names

        for (_, group) in groupedNames where group.count > 1 {
            for configuration in group {
                let currentName = updatedNames[configuration.domainIdentifier] ?? configuration.displayName
                updatedNames[configuration.domainIdentifier] = currentName + suffix(configuration)
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
        let diagnosticError = FileProviderDomainRegistrationDiagnostics
            .applicationExtensionNotFoundError(in: error) ?? nsError
        let category = appErrorCategory(for: error, nsError: nsError, preferredCategory: preferredCategory)
        let recoverySuggestion = FileProviderDomainRegistrationDiagnostics
            .recoverySuggestion(for: error)
            ?? (error as? LocalizedError)?.recoverySuggestion
        let diagnosticSummary = FileProviderDomainRegistrationDiagnostics
            .diagnosticSummary(for: error)
            ?? appDiagnosticSummary(for: category)
        return KDriveProviderActivityErrorDiagnostic(
            errorCategory: category,
            underlyingErrorDomain: diagnosticError.domain,
            underlyingErrorCode: diagnosticError.code,
            recoverySuggestion: recoverySuggestion,
            diagnosticSummary: diagnosticSummary
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

private enum FileProviderDomainRegistrationDiagnostics {
    static let userFacingMessage =
        "macOS cannot find this app's File Provider extension. Run potassiumProvider on My Mac from Xcode (not a test build), then try again."

    private static let errorDomain = "NSFileProviderErrorDomain"
    private static let applicationExtensionNotFoundCode = -2014

    static func applicationExtensionNotFoundError(in error: Error) -> NSError? {
        var candidate: NSError? = error as NSError

        // File Provider commonly wraps -2014 in a generic -2001 error. Keep
        // following NSUnderlyingErrorKey so the activity shows the actionable
        // cause rather than only the outer wrapper.
        for _ in 0..<16 {
            guard let current = candidate else { return nil }
            if current.domain == errorDomain,
               current.code == applicationExtensionNotFoundCode {
                return current
            }
            candidate = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return nil
    }

    static func recoverySuggestion(for error: Error) -> String? {
        guard applicationExtensionNotFoundError(in: error) != nil else { return nil }
        return "Run the containing potassiumProvider app with the My Mac destination, not an XCTest/test-derived app. If it still fails, clean stale File Provider registrations and relaunch the app."
    }

    static func diagnosticSummary(for error: Error) -> String? {
        guard applicationExtensionNotFoundError(in: error) != nil else { return nil }
        return "macOS rejected domain registration because the app bundle did not expose a usable File Provider extension (NSFileProviderErrorDomain -2014)."
    }
}

enum PotassiumProviderAppModelError: Error, Equatable, LocalizedError {
    case missingAccount
    case missingToken
    case expiredToken

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            return "Choose an account before loading drives."
        case .missingToken:
            return "Connect to kDrive before loading drives."
        case .expiredToken:
            return "The saved access token has expired. Reconnect to kDrive."
        }
    }
}

private enum VaultDomainRegistrationError: Error, LocalizedError {
    case vaultAlreadyRegistered

    var errorDescription: String? {
        "This encrypted vault is already registered on this device."
    }
}

private enum KnownFolderSetupError: Error, LocalizedError {
    case legacyMigrationRequired
    case partialClaimRequiresRepair
    case preflightFailed
    case unsupportedEncryptedVaultFormat

    var errorDescription: String? {
        switch self {
        case .legacyMigrationRequired:
            return "Desktop and Documents are owned by a legacy plaintext Potassium domain. Safe encrypted migration is not implemented, so ownership cannot switch to this vault."
        case .partialClaimRequiresRepair:
            return "Only one known folder is currently claimed. Stop the partial configuration before enabling both folders again."
        case .preflightFailed:
            return "Desktop and Documents protection did not pass its unlock and reachability checks."
        case .unsupportedEncryptedVaultFormat:
            return "This experimental encrypted-vault format is unsupported. Export any recoverable data with an older build; this app will not activate or mutate it."
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
