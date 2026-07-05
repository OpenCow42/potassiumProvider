import Combine
import Foundation
import PotassiumProviderCore

@MainActor
final class PotassiumProviderAppModel: ObservableObject {
    @Published private(set) var token: KDriveOAuthToken?
    @Published private(set) var drives: [KDriveDriveSummary] = []
    @Published private(set) var domains: [ProviderDomainConfiguration] = []
    @Published private(set) var isConnecting = false
    @Published private(set) var isLoadingDrives = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    @Published var manualAccessToken = ""
    @Published var selectedDriveID: Int?
    @Published var manualDriveID = ""
    @Published var manualDriveName = ""

    private let domainStore: any DomainConfigurationStoring
    private let tokenStore: any OAuthTokenStoring
    private let oauthAuthenticator: any KDriveOAuthAuthenticating
    private let domainRegistrar: any ProviderDomainRegistering
    private let snapshotStore: (any KDriveSnapshotStoring)?
    private let eventStore: (any KDriveProviderEventStoring)?
    private let fileProviderFactory: (String) -> any KDriveFileProviding

    init(
        domainStore: (any DomainConfigurationStoring)? = nil,
        tokenStore: (any OAuthTokenStoring)? = nil,
        oauthAuthenticator: (any KDriveOAuthAuthenticating)? = nil,
        domainRegistrar: (any ProviderDomainRegistering)? = nil,
        snapshotStore: (any KDriveSnapshotStoring)? = nil,
        eventStore: (any KDriveProviderEventStoring)? = nil,
        automaticallyReloadStoredState: Bool = true,
        fileProviderFactory: @escaping (String) -> any KDriveFileProviding = { PotassiumKDriveService(bearerToken: $0) }
    ) {
        self.domainStore = domainStore ?? Self.makeDefaultDomainStore()
        self.tokenStore = tokenStore ?? KeychainOAuthTokenStore(accessGroup: ProviderConstants.keychainAccessGroup)
        self.oauthAuthenticator = oauthAuthenticator ?? KDriveOAuthWebAuthenticator()
        self.domainRegistrar = domainRegistrar ?? FileProviderDomainRegistrar()
        self.snapshotStore = snapshotStore ?? Self.makeDefaultSnapshotStore()
        self.eventStore = eventStore ?? Self.makeDefaultEventStore()
        self.fileProviderFactory = fileProviderFactory
        statusMessage = "Not connected"
        if automaticallyReloadStoredState {
            Task { await reloadStoredState() }
        }
    }

    var isConnected: Bool {
        token != nil
    }

    var canLoadDrives: Bool {
        token != nil && isLoadingDrives == false
    }

    var canAddDomain: Bool {
        resolvedDriveDraft() != nil
    }

    var selectedDrive: KDriveDriveSummary? {
        guard let selectedDriveID else { return nil }
        return drives.first { $0.id == selectedDriveID }
    }

    var providerEventStore: (any KDriveProviderEventStoring)? {
        eventStore
    }

    func reloadStoredState() async {
        do {
            token = try await tokenStore.loadToken()
            let synchronizedState = try await synchronizedDomainConfigurations()
            domains = synchronizedState.configurations
            if let synchronizationError = synchronizedState.registrationError {
                errorMessage = "Could not refresh Finder domain names: \(synchronizationError.localizedDescription)"
                statusMessage = nil
            } else {
                errorMessage = nil
                statusMessage = token == nil ? "Not connected" : "Connected to kDrive."
            }
        } catch {
            errorMessage = "Could not load saved provider state: \(error.localizedDescription)"
        }
    }

    func connectWithOAuth() async {
        isConnecting = true
        errorMessage = nil
        statusMessage = "Opening Infomaniak login."
        defer { isConnecting = false }

        do {
            let token = try await oauthAuthenticator.authenticate()
            try await saveConnectedToken(token)
            statusMessage = "Connected. Loading kDrives."
            await loadDrives()
        } catch {
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
            try await saveConnectedToken(token)
            manualAccessToken = ""
            statusMessage = "Access token saved. Loading kDrives."
            await loadDrives()
        } catch {
            errorMessage = "Could not save the access token: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func loadDrives() async {
        do {
            let token = try await usableToken()
            isLoadingDrives = true
            errorMessage = nil
            defer { isLoadingDrives = false }

            drives = try await fileProviderFactory(token.accessToken).listDrives()
            if selectedDriveID == nil || drives.contains(where: { $0.id == selectedDriveID }) == false {
                selectedDriveID = drives.first?.id
            }
            refreshDraftFromSelectedDrive()
            statusMessage = drives.isEmpty ? "No kDrives returned for this account." : "Loaded \(drives.count) kDrive account."
        } catch {
            errorMessage = "Could not load kDrives: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func addDomain() async {
        guard let draft = resolvedDriveDraft() else {
            errorMessage = "Choose or enter a kDrive before adding a domain."
            statusMessage = nil
            return
        }

        var savedConfiguration: ProviderDomainConfiguration?
        do {
            let now = Date()
            let configuration = ProviderDomainConfiguration(
                displayName: ProviderDomainConfiguration.finderDisplayName(forDriveName: draft.name),
                driveID: draft.id,
                driveName: draft.name,
                createdAt: now,
                updatedAt: now
            )

            try await domainStore.save(configuration)
            savedConfiguration = configuration
            domains = try await domainStore.allConfigurations()
            try await domainRegistrar.addDomain(for: configuration)
            statusMessage = "Added \(configuration.displayName) to Files."
            errorMessage = nil
        } catch {
            if let savedConfiguration {
                await rollbackFailedDomainAddition(savedConfiguration)
            }
            errorMessage = "Could not add the provider domain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func removeDomain(_ configuration: ProviderDomainConfiguration) async {
        do {
            try await domainRegistrar.removeDomain(for: configuration)
            try await snapshotStore?.removeSnapshots(domainIdentifier: configuration.domainIdentifier)
            try await eventStore?.removeEvents(domainIdentifier: configuration.domainIdentifier)
            try await domainStore.remove(domainIdentifier: configuration.domainIdentifier)
            domains = try await domainStore.allConfigurations()
            statusMessage = "Removed \(configuration.displayName) from Files."
            errorMessage = nil
        } catch {
            errorMessage = "Could not remove the provider domain: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    func disconnect() async {
        do {
            try await tokenStore.deleteToken()
            token = nil
            drives = []
            selectedDriveID = nil
            manualAccessToken = ""
            statusMessage = "Disconnected."
            errorMessage = nil
        } catch {
            errorMessage = "Could not remove the saved token: \(error.localizedDescription)"
            statusMessage = nil
        }
    }

    private func saveConnectedToken(_ token: KDriveOAuthToken) async throws {
        try await tokenStore.saveToken(token)
        self.token = token
        errorMessage = nil
    }

    private func rollbackFailedDomainAddition(_ configuration: ProviderDomainConfiguration) async {
        try? await snapshotStore?.removeSnapshots(domainIdentifier: configuration.domainIdentifier)
        try? await domainStore.remove(domainIdentifier: configuration.domainIdentifier)

        if let storedDomains = try? await domainStore.allConfigurations() {
            domains = storedDomains
        } else {
            domains.removeAll { $0.domainIdentifier == configuration.domainIdentifier }
        }
    }

    private func usableToken() async throws -> KDriveOAuthToken {
        var loadedToken = token
        if loadedToken == nil {
            loadedToken = try await tokenStore.loadToken()
        }

        guard var token = loadedToken else {
            throw PotassiumProviderAppModelError.missingToken
        }

        if token.shouldRefresh() {
            guard let refreshToken = token.refreshToken else {
                throw PotassiumProviderAppModelError.expiredToken
            }
            token = try await KDriveOAuthClient.refresh(refreshToken: refreshToken)
            try await tokenStore.saveToken(token)
            self.token = token
        }

        return token
    }

    private func refreshDraftFromSelectedDrive() {
        guard let selectedDrive else { return }
        manualDriveID = String(selectedDrive.id)
        manualDriveName = selectedDrive.name
    }

    private func resolvedDriveDraft() -> (id: Int, name: String)? {
        if let selectedDrive {
            return (selectedDrive.id, selectedDrive.name)
        }

        guard let id = Int(trimmed(manualDriveID)), id > 0 else {
            return nil
        }
        let name = trimmed(manualDriveName).nilIfEmpty ?? "kDrive \(id)"
        return (id, name)
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

    private func synchronizedDomainConfigurations() async throws -> (configurations: [ProviderDomainConfiguration], registrationError: Error?) {
        var configurations = try await domainStore.allConfigurations()
        var registrationError: Error?

        for index in configurations.indices {
            if configurations[index].normalizeFinderDisplayName() {
                try await domainStore.save(configurations[index])
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
}

enum PotassiumProviderAppModelError: Error, Equatable, LocalizedError {
    case missingToken
    case expiredToken

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "Connect to kDrive before loading drives."
        case .expiredToken:
            return "The saved access token has expired. Reconnect to kDrive."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
