import PotassiumProviderCore
import SwiftUI

#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @State private var accountPendingLogout: ProviderAccount?
    @State private var selectedTab: ProviderAppTab
    #if os(macOS)
    @State private var drivePendingStorageSelection: ProviderDriveStorageRequest?
    @State private var domainPendingStorageChange: ProviderDomainConfiguration?
    #endif

    init(model: PotassiumProviderAppModel) {
        _model = ObservedObject(wrappedValue: model)
        _selectedTab = State(initialValue: ProviderAppTabSelectionPolicy.defaultSelection(
            configuredDomainCount: model.domains.count
        ))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ProviderStatusView(appModel: model) {
                selectedTab = .setup
            }
            .tabItem {
                Label("Status", systemImage: "gauge.medium")
            }
            .tag(ProviderAppTab.status)

            setupView
                .tabItem {
                    Label("Setup", systemImage: "externaldrive.connected.to.line.below")
                }
                .tag(ProviderAppTab.setup)

            ConflictLogView(eventStore: model.providerEventStore)
                .tabItem {
                    Label("Activities", systemImage: "clock.arrow.circlepath")
                }
                .tag(ProviderAppTab.activities)
        }
        .onAppear {
            selectedTab = ProviderAppTabSelectionPolicy.defaultSelection(
                configuredDomainCount: model.domains.count
            )
        }
    }

    @ViewBuilder
    private var setupView: some View {
        NavigationStack {
            List {
                addAccountSection

                if model.accounts.isEmpty {
                    Section {
                        Label("No accounts connected", systemImage: "person.crop.circle.badge.questionmark")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.accounts) { account in
                        accountSection(account)
                    }
                }

                if let statusMessage = model.statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("potassiumProvider")
            .task(id: setupAutoLoadTaskID) {
                await model.loadDrivesForAccountsIfPossible()
            }
            .toolbar {
                ToolbarItem(placement: refreshToolbarPlacement) {
                    Button {
                        Task {
                            for account in model.accounts {
                                await model.loadDrives(accountIdentifier: account.accountIdentifier)
                            }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.accounts.isEmpty)
                }
            }
            .alert("kDrive", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert(item: $accountPendingLogout) { account in
                Alert(
                    title: Text("Log Out \(account.displayName)?"),
                    message: Text("This removes this account's drives from Files and clears its local provider state."),
                    primaryButton: .destructive(Text("Log Out")) {
                        Task { await model.logoutAccount(account) }
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        #if os(macOS)
        .sheet(item: $drivePendingStorageSelection) { request in
            ProviderStorageSelectionSheet(
                purpose: .add(driveName: request.drive.name),
                selectExternalVolume: model.selectExternalVolume
            ) { externalVolume in
                Task {
                    if let externalVolume {
                        await model.addDomain(
                            accountIdentifier: request.accountIdentifier,
                            drive: request.drive,
                            externalVolume: externalVolume
                        )
                    } else {
                        await model.addDomain(
                            accountIdentifier: request.accountIdentifier,
                            drive: request.drive
                        )
                    }
                }
            }
        }
        .sheet(item: $domainPendingStorageChange) { configuration in
            ProviderStorageSelectionSheet(
                purpose: .move(
                    driveName: configuration.driveName,
                    currentStorageLocation: configuration.storageLocation
                ),
                selectExternalVolume: model.selectExternalVolume
            ) { externalVolume in
                Task {
                    await model.moveDomain(
                        configuration,
                        toExternalVolume: externalVolume
                    )
                }
            }
        }
        .alert(
            "Local Data Preserved",
            isPresented: preservedDataAlertBinding,
            presenting: model.preservedDataLocation
        ) { location in
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([location.url])
                model.preservedDataLocation = nil
            }
            .accessibilityIdentifier("preserved-data-reveal-in-finder")
            Button("Dismiss", role: .cancel) {
                model.preservedDataLocation = nil
            }
            .accessibilityIdentifier("preserved-data-dismiss")
        } message: { location in
            Text("macOS preserved local data from \(location.driveName) at \(location.url.path). Review it before deleting it.")
        }
        #endif
    }

    private var addAccountSection: some View {
        Section("Accounts") {
            Button {
                Task { await model.connectWithOAuth() }
            } label: {
                Label(model.isConnecting ? "Connecting" : "Add Infomaniak Account", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(model.isConnecting)

            HStack {
                SecureField("Access token", text: $model.manualAccessToken)
                    .platformPasswordEntry()
                Button {
                    Task { await model.saveManualAccessToken() }
                } label: {
                    Label("Save Token", systemImage: "key.fill")
                }
                .disabled(model.manualAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func accountSection(_ account: ProviderAccount) -> some View {
        Section {
            HStack(spacing: 12) {
                Label {
                    TextField(
                        "Account name",
                        text: Binding {
                            model.account(accountIdentifier: account.accountIdentifier)?.displayName ?? account.displayName
                        } set: { newValue in
                            Task {
                                await model.renameAccount(
                                    accountIdentifier: account.accountIdentifier,
                                    displayName: newValue
                                )
                            }
                        }
                    )
                } icon: {
                    Image(systemName: account.authenticationKind == .oauth ? "person.crop.circle" : "key")
                }

                Spacer()

                Button {
                    Task { await model.loadDrives(accountIdentifier: account.accountIdentifier) }
                } label: {
                    Label("Refresh Drives", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .disabled(model.canLoadDrives(for: account.accountIdentifier) == false)

                Button(role: .destructive) {
                    accountPendingLogout = account
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .labelStyle(.iconOnly)
            }

            drivesView(account)
        } header: {
            Text(account.displayName)
        }
    }

    @ViewBuilder
    private func drivesView(_ account: ProviderAccount) -> some View {
        let drives = model.drives(for: account.accountIdentifier)
        let configuredDomains = model.domains(for: account.accountIdentifier)
        let configuredDomainsByDriveID = Dictionary(uniqueKeysWithValues: configuredDomains.map { ($0.driveID, $0) })
        let loadedDriveIDs = Set(drives.map(\.id))
        let configuredDomainsWithoutLoadedDrive = configuredDomains.filter { loadedDriveIDs.contains($0.driveID) == false }

        if drives.isEmpty && configuredDomainsWithoutLoadedDrive.isEmpty {
            Button {
                Task { await model.loadDrives(accountIdentifier: account.accountIdentifier) }
            } label: {
                Label(
                    model.isLoadingDrives(for: account.accountIdentifier) ? "Loading Drives" : "Load Drives",
                    systemImage: "externaldrive.connected.to.line.below"
                )
            }
            .disabled(model.canLoadDrives(for: account.accountIdentifier) == false)
        } else {
            ForEach(drives) { drive in
                DriveConfigurationRow(
                    driveID: drive.id,
                    driveName: drive.name,
                    detail: "Drive \(drive.id) · \(drive.role)",
                    configuration: configuredDomainsByDriveID[drive.id],
                    knownFolderSyncState: configuredDomainsByDriveID[drive.id].map(model.knownFolderSyncState(for:)) ?? .unavailable,
                    isChangingKnownFolderSync: configuredDomainsByDriveID[drive.id].map(model.isChangingKnownFolderSync(for:)) ?? false,
                    placementState: configuredDomainsByDriveID[drive.id].map(model.placementState(for:)),
                    canMutate: configuredDomainsByDriveID[drive.id].map(model.canMutate) ?? true,
                    isTransitioning: configuredDomainsByDriveID[drive.id].map(model.isTransitioning) ?? false
                ) {
                    addDomain(accountIdentifier: account.accountIdentifier, drive: drive)
                } remove: { configuration in
                    Task { await model.removeDomain(configuration) }
                } changeStorage: { configuration in
                    beginStorageChange(for: configuration)
                } repair: { configuration in
                    Task { await model.repairDomain(configuration) }
                } enableKnownFolderSync: { configuration in
                    Task { await model.enableKnownFolderSync(for: configuration) }
                } disableKnownFolderSync: { configuration in
                    Task { await model.disableKnownFolderSync(for: configuration) }
                }
            }

            ForEach(configuredDomainsWithoutLoadedDrive) { domain in
                DriveConfigurationRow(
                    driveID: domain.driveID,
                    driveName: domain.driveName,
                    detail: "Drive \(domain.driveID)",
                    configuration: domain,
                    knownFolderSyncState: model.knownFolderSyncState(for: domain),
                    isChangingKnownFolderSync: model.isChangingKnownFolderSync(for: domain),
                    placementState: model.placementState(for: domain),
                    canMutate: model.canMutate(domain),
                    isTransitioning: model.isTransitioning(domain)
                ) {
                    Task { await model.addDomain(accountIdentifier: account.accountIdentifier) }
                } remove: { configuration in
                    Task { await model.removeDomain(configuration) }
                } changeStorage: { configuration in
                    beginStorageChange(for: configuration)
                } repair: { configuration in
                    Task { await model.repairDomain(configuration) }
                } enableKnownFolderSync: { configuration in
                    Task { await model.enableKnownFolderSync(for: configuration) }
                } disableKnownFolderSync: { configuration in
                    Task { await model.disableKnownFolderSync(for: configuration) }
                }
            }
        }
    }

    private func addDomain(
        accountIdentifier: String,
        drive: KDriveDriveSummary
    ) {
        #if os(macOS)
        drivePendingStorageSelection = ProviderDriveStorageRequest(
            accountIdentifier: accountIdentifier,
            drive: drive
        )
        #else
        Task {
            await model.addDomain(
                accountIdentifier: accountIdentifier,
                drive: drive
            )
        }
        #endif
    }

    private func beginStorageChange(for configuration: ProviderDomainConfiguration) {
        #if os(macOS)
        domainPendingStorageChange = configuration
        #endif
    }

    #if os(macOS)
    private var preservedDataAlertBinding: Binding<Bool> {
        Binding {
            model.preservedDataLocation != nil
        } set: { isPresented in
            if isPresented == false {
                model.preservedDataLocation = nil
            }
        }
    }
    #endif

    private var errorBinding: Binding<Bool> {
        Binding {
            model.errorMessage != nil
        } set: { isPresented in
            if isPresented == false {
                model.errorMessage = nil
            }
        }
    }

    private var refreshToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }

    private var setupAutoLoadTaskID: String {
        model.accounts.map(\.accountIdentifier).joined(separator: "|")
    }
}

#if os(macOS)
private struct ProviderDriveStorageRequest: Identifiable {
    let id = UUID()
    let accountIdentifier: String
    let drive: KDriveDriveSummary
}
#endif

enum ProviderAppTab: Hashable {
    case status
    case setup
    case activities
}

enum ProviderAppTabSelectionPolicy {
    static func defaultSelection(configuredDomainCount _: Int) -> ProviderAppTab {
        .status
    }
}

private struct DriveConfigurationRow: View {
    let driveID: Int
    let driveName: String
    let detail: String
    let configuration: ProviderDomainConfiguration?
    let knownFolderSyncState: ProviderKnownFolderSyncState
    let isChangingKnownFolderSync: Bool
    let placementState: ProviderDomainPlacementState?
    let canMutate: Bool
    let isTransitioning: Bool
    let add: () -> Void
    let remove: (ProviderDomainConfiguration) -> Void
    let changeStorage: (ProviderDomainConfiguration) -> Void
    let repair: (ProviderDomainConfiguration) -> Void
    let enableKnownFolderSync: (ProviderDomainConfiguration) -> Void
    let disableKnownFolderSync: (ProviderDomainConfiguration) -> Void
    @State private var isStopSyncConfirmationPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(driveName)
                        .font(.headline)
                    Text(configuration == nil ? detail : "\(detail) · In Files")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let configuration {
                    Button(role: .destructive) {
                        remove(configuration)
                    } label: {
                        Label("Remove from Files", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(mutationControlsDisabled)
                    .accessibilityIdentifier("domain-remove-\(configuration.configurationIdentifier)")
                } else {
                    Button(action: add) {
                        Label("Use in Files", systemImage: "folder.badge.plus")
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("drive-use-in-files-\(driveID)")
                }
            }

            #if os(macOS)
            if let configuration {
                Divider()
                storageView(for: configuration)

                Divider()
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Desktop & Documents")
                            .font(.subheadline.weight(.medium))
                        Text(knownFolderDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isChangingKnownFolderSync {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        knownFolderAction(for: configuration)
                    }
                }
                .accessibilityIdentifier("domain-known-folders-\(configuration.configurationIdentifier)")
                .confirmationDialog(
                    "Stop syncing Desktop and Documents?",
                    isPresented: $isStopSyncConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Stop Syncing", role: .destructive) {
                        disableKnownFolderSync(configuration)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("macOS will stop replicating both folders with kDrive. Remote files in /private are not deleted.")
                }
            }
            #endif
        }
    }

    #if os(macOS)
    @ViewBuilder
    private func storageView(for configuration: ProviderDomainConfiguration) -> some View {
        let state = placementState ?? .registering
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: configuration.storageLocation.isExternal ? "externaldrive.fill" : "internaldrive.fill")
                .foregroundStyle(state.isAttentionRequired ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Storage")
                    .font(.subheadline.weight(.medium))
                Text(configuration.storageLocation.userFacingTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label(state.title, systemImage: placementStateSystemImage(state))
                    .font(.caption)
                    .foregroundStyle(state.isAttentionRequired ? .orange : .secondary)
                    .accessibilityIdentifier("domain-storage-state-\(configuration.configurationIdentifier)")
                if let detail = state.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isTransitioning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(state.title)
            } else if state.isAttentionRequired {
                Button("Repair") {
                    repair(configuration)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("domain-storage-repair-\(configuration.configurationIdentifier)")
            } else {
                Button("Change Storage") {
                    changeStorage(configuration)
                }
                .buttonStyle(.bordered)
                .disabled(mutationControlsDisabled)
                .accessibilityIdentifier("domain-storage-change-\(configuration.configurationIdentifier)")
            }
        }
        .accessibilityIdentifier("domain-storage-\(configuration.configurationIdentifier)")
    }

    private func placementStateSystemImage(_ state: ProviderDomainPlacementState) -> String {
        switch state {
        case .connected:
            "checkmark.circle.fill"
        case .authenticationRequired:
            "person.crop.circle.badge.exclamationmark"
        case .volumeUnavailable:
            "externaldrive.badge.exclamationmark"
        case .registering, .moving:
            "arrow.triangle.2.circlepath"
        case .needsRepair:
            "wrench.and.screwdriver.fill"
        }
    }

    private var knownFolderDetail: String {
        switch knownFolderSyncState {
        case .active:
            return "Syncing with /private/Desktop and /private/Documents"
        case .partial:
            return "Partially enabled · stop and enable again to repair"
        case .inactive:
            return "Sync both folders with kDrive /private"
        case .unavailable:
            return "File Provider status unavailable"
        }
    }

    @ViewBuilder
    private func knownFolderAction(for configuration: ProviderDomainConfiguration) -> some View {
        switch knownFolderSyncState {
        case .active, .partial:
            Button("Stop Syncing") {
                isStopSyncConfirmationPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(mutationControlsDisabled)
            .accessibilityIdentifier("domain-known-folders-stop-\(configuration.configurationIdentifier)")
        case .inactive:
            Button("Sync") {
                enableKnownFolderSync(configuration)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mutationControlsDisabled)
            .accessibilityIdentifier("domain-known-folders-enable-\(configuration.configurationIdentifier)")
        case .unavailable:
            Text("Unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
    #endif

    private var mutationControlsDisabled: Bool {
        #if os(macOS)
        canMutate == false || isTransitioning
        #else
        false
        #endif
    }
}

#Preview {
    ContentView(model: PotassiumProviderAppModel(
        accountStore: ProviderAccountFileStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("potassiumProviderPreviewAccounts", isDirectory: true)
        ),
        domainStore: DomainConfigurationFileStore(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("potassiumProviderPreview", isDirectory: true)
        ),
        tokenStore: InMemoryOAuthTokenStore()
    ))
}

private extension View {
    @ViewBuilder
    func platformPasswordEntry() -> some View {
        #if canImport(UIKit)
        self
            .textContentType(.password)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder
    func platformNumberEntry() -> some View {
        #if canImport(UIKit)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
}
