import PotassiumProviderCore
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

enum ProviderSetupRoute: Hashable {
    case addAccount
    case account(String)
    case drive(ProviderDriveKey)
}

struct ProviderDriveDescriptor: Identifiable, Equatable {
    var id: ProviderDriveKey {
        ProviderDriveKey(accountIdentifier: accountIdentifier, driveID: driveID)
    }

    let accountIdentifier: String
    let driveID: Int
    let remote: KDriveDriveSummary?
    let configurations: [ProviderDomainConfiguration]

    var configuration: ProviderDomainConfiguration? {
        configurations.first(where: { $0.encryptionMode == .opaqueVaultV2 })
            ?? configurations.first(where: { $0.encryptionMode == .opaqueVaultV1 })
            ?? configurations.first
    }

    var encryptedConfiguration: ProviderDomainConfiguration? {
        configurations.first { $0.encryptionMode == .opaqueVaultV2 }
    }

    var legacyConfigurations: [ProviderDomainConfiguration] {
        configurations.filter { $0.encryptionMode == .legacyPlaintext }
    }

    var name: String {
        remote?.name ?? configurations.first?.driveName ?? "kDrive \(driveID)"
    }

    var role: String? {
        guard let role = remote?.role, role.isEmpty == false else { return nil }
        return role
    }

    var remoteStatus: String? {
        guard let status = remote?.status, status.isEmpty == false else { return nil }
        return status
    }

    var isInMaintenance: Bool {
        remote?.isInMaintenance ?? false
    }

    var isConfigured: Bool {
        configurations.isEmpty == false
    }

    var remoteDetailsAreAvailable: Bool {
        remote != nil
    }

    static func merge(
        accountIdentifier: String,
        drives: [KDriveDriveSummary],
        configurations: [ProviderDomainConfiguration]
    ) -> [ProviderDriveDescriptor] {
        let configurationsByDriveID = Dictionary(grouping: configurations, by: \.driveID)

        var seenDriveIDs: Set<Int> = []
        var descriptors = drives.compactMap { drive -> ProviderDriveDescriptor? in
            guard seenDriveIDs.insert(drive.id).inserted else { return nil }
            return ProviderDriveDescriptor(
                accountIdentifier: accountIdentifier,
                driveID: drive.id,
                remote: drive,
                configurations: configurationsByDriveID[drive.id] ?? []
            )
        }

        descriptors.append(contentsOf: configurationsByDriveID
            .filter { seenDriveIDs.insert($0.key).inserted }
            .map { driveID, configurations in
                ProviderDriveDescriptor(
                    accountIdentifier: accountIdentifier,
                    driveID: driveID,
                    remote: nil,
                    configurations: configurations
                )
            })
        return descriptors
    }
}

struct ProviderSetupView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [ProviderSetupRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            accountList
                .navigationDestination(for: ProviderSetupRoute.self) { route in
                    destination(for: route)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let errorMessage = model.errorMessage {
                ProviderSetupErrorBanner(message: errorMessage) {
                    model.errorMessage = nil
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.16) : .snappy(duration: 0.28, extraBounce: 0),
            value: model.errorMessage
        )
    }

    private var accountList: some View {
        List {
            Section {
                NavigationLink(value: ProviderSetupRoute.addAccount) {
                    Label("Add Infomaniak Account", systemImage: "person.crop.circle.badge.plus")
                        .font(.headline)
                }
                .accessibilityIdentifier("setup.addAccount")
            }
            .disabled(model.isReloadingStoredState)

            Section("Accounts") {
                if model.isReloadingStoredState && model.accounts.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading saved accounts…")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading saved accounts")
                } else if model.accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts Connected",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Add an Infomaniak account to discover its kDrives.")
                    )
                } else {
                    ForEach(model.accounts) { account in
                        NavigationLink(value: ProviderSetupRoute.account(account.accountIdentifier)) {
                            ProviderAccountRow(
                                account: account,
                                loadedDriveCount: model.drives(for: account.accountIdentifier).count,
                                configuredDriveCount: model.domains(for: account.accountIdentifier).count,
                                isLoading: model.isLoadingDrives(for: account.accountIdentifier)
                            )
                        }
                        .accessibilityIdentifier("setup.account.\(account.accountIdentifier)")
                    }
                }
            }

            if model.isReloadingStoredState == false, let statusMessage = model.statusMessage {
                Section {
                    ProviderFeedbackLabel(message: statusMessage)
                }
            }
        }
        .navigationTitle("Setup")
        .providerNavigationAnimation(animatesInitialAppearance: false)
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
                    Label("Refresh All Accounts", systemImage: "arrow.clockwise")
                }
                .disabled(
                    model.isReloadingStoredState ||
                    model.accounts.isEmpty ||
                    model.loadingDriveAccountIdentifiers.isEmpty == false
                )
                .accessibilityIdentifier("setup.refreshAll")
            }
        }
    }

    @ViewBuilder
    private func destination(for route: ProviderSetupRoute) -> some View {
        switch route {
        case .addAccount:
            ProviderAddAccountView(model: model)
                .providerNavigationAnimation()
        case .account(let accountIdentifier):
            ProviderAccountManagementView(
                model: model,
                accountIdentifier: accountIdentifier
            ) {
                path.removeAll()
            }
            .providerNavigationAnimation()
        case .drive(let key):
            ProviderDriveManagementView(model: model, key: key)
                .providerNavigationAnimation()
        }
    }

    private var setupAutoLoadTaskID: String {
        model.accounts.map(\.accountIdentifier).joined(separator: "|")
    }

    private var refreshToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }
}

private struct ProviderAccountRow: View {
    let account: ProviderAccount
    let loadedDriveCount: Int
    let configuredDriveCount: Int
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.authenticationKind.systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.headline)
                Text(account.authenticationKind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(loadedDriveCount) discovered · \(configuredDriveCount) in Files")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading drives")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProviderAddAccountView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                Button {
                    Task {
                        let existingAccountIDs = Set(model.accounts.map(\.accountIdentifier))
                        await model.connectWithOAuth()
                        if model.accounts.contains(where: { existingAccountIDs.contains($0.accountIdentifier) == false }) {
                            dismiss()
                        }
                    }
                } label: {
                    HStack {
                        Label(
                            model.isConnecting ? "Connecting…" : "Continue with Infomaniak",
                            systemImage: "person.crop.circle.badge.plus"
                        )
                        Spacer()
                        if model.isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(model.isConnecting)
                .accessibilityIdentifier("addAccount.oauth")
            } header: {
                Text("Infomaniak Account")
            } footer: {
                Text("Sign in through Infomaniak to connect and automatically refresh your account.")
            }

            Section {
                SecureField("Access token", text: $model.manualAccessToken)
                    .platformPasswordEntry()
                    .accessibilityIdentifier("addAccount.manualToken")

                Button {
                    Task {
                        let existingAccountIDs = Set(model.accounts.map(\.accountIdentifier))
                        await model.saveManualAccessToken()
                        if model.accounts.contains(where: { existingAccountIDs.contains($0.accountIdentifier) == false }) {
                            dismiss()
                        }
                    }
                } label: {
                    Label("Save Access Token", systemImage: "key.fill")
                }
                .disabled(model.manualAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("addAccount.saveManualToken")
            } header: {
                Text("Advanced")
            } footer: {
                Text("Manual tokens are intended for development and may stop working when they expire.")
            }
        }
        .navigationTitle("Add Account")
    }
}

private struct ProviderAccountManagementView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    let accountIdentifier: String
    let didRemoveAccount: () -> Void

    @State private var isRenamePresented = false
    @State private var renameDraft = ""
    @State private var isLogoutConfirmationPresented = false

    var body: some View {
        Group {
            if let account {
                accountForm(account)
            } else {
                ContentUnavailableView {
                    Label("Account Unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("This account is no longer connected.")
                } actions: {
                    Button("Back to Setup", action: didRemoveAccount)
                }
            }
        }
        .navigationTitle(account?.displayName ?? "Account")
        .toolbar {
            ToolbarItem(placement: refreshToolbarPlacement) {
                Button {
                    Task { await model.loadDrives(accountIdentifier: accountIdentifier) }
                } label: {
                    Label("Refresh Drives", systemImage: "arrow.clockwise")
                }
                .disabled(
                    model.canLoadDrives(for: accountIdentifier) == false ||
                    model.isPerformingDriveAction(for: accountIdentifier)
                )
                .accessibilityIdentifier("account.refreshDrives")
            }
        }
        .alert("Rename Account", isPresented: $isRenamePresented) {
            TextField("Account name", text: $renameDraft)
            Button("Save") {
                let submittedName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    await model.renameAccount(
                        accountIdentifier: accountIdentifier,
                        displayName: submittedName
                    )
                }
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose the local name shown for this account.")
        }
        .confirmationDialog(
            "Log out of \(account?.displayName ?? "this account")?",
            isPresented: $isLogoutConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Log Out", role: .destructive) {
                guard let account else { return }
                Task {
                    await model.logoutAccount(account)
                    if model.account(accountIdentifier: accountIdentifier) == nil {
                        didRemoveAccount()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the account’s drives from Files and clears their provider-local state and saved credentials. Remote kDrive files are not deleted.")
        }
    }

    private var account: ProviderAccount? {
        model.account(accountIdentifier: accountIdentifier)
    }

    private var driveDescriptors: [ProviderDriveDescriptor] {
        ProviderDriveDescriptor.merge(
            accountIdentifier: accountIdentifier,
            drives: model.drives(for: accountIdentifier),
            configurations: model.domains(for: accountIdentifier)
        )
    }

    private func accountForm(_ account: ProviderAccount) -> some View {
        List {
            Section("Account") {
                LabeledContent("Name", value: account.displayName)
                LabeledContent("Authentication", value: account.authenticationKind.title)

                Button {
                    renameDraft = account.displayName
                    isRenamePresented = true
                } label: {
                    Label("Rename Account", systemImage: "pencil")
                }
                .accessibilityIdentifier("account.rename")
            }

            Section("Drives") {
                if model.isLoadingDrives(for: accountIdentifier) && driveDescriptors.isEmpty {
                    HStack {
                        ProgressView()
                        Text("Loading kDrives…")
                    }
                    .accessibilityElement(children: .combine)
                } else if driveDescriptors.isEmpty {
                    ContentUnavailableView {
                        Label("No kDrives Available", systemImage: "externaldrive.badge.questionmark")
                    } description: {
                        Text("Refresh this account to discover its kDrives.")
                    } actions: {
                        Button("Load Drives") {
                            Task { await model.loadDrives(accountIdentifier: accountIdentifier) }
                        }
                        .disabled(model.canLoadDrives(for: accountIdentifier) == false)
                    }
                } else {
                    ForEach(driveDescriptors) { descriptor in
                        NavigationLink(value: ProviderSetupRoute.drive(descriptor.id)) {
                            ProviderDriveRow(descriptor: descriptor)
                        }
                        .accessibilityIdentifier("account.drive.\(descriptor.driveID)")
                    }
                }
            }

            if let statusMessage = model.statusMessage {
                Section {
                    ProviderFeedbackLabel(message: statusMessage)
                }
            }

            Section {
                Button("Log Out", role: .destructive) {
                    isLogoutConfirmationPresented = true
                }
                .disabled(model.isPerformingDriveAction(for: accountIdentifier))
                .accessibilityIdentifier("account.logout")
            } footer: {
                Text("Logging out removes this account’s File Provider domains and local state. It does not delete remote files.")
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
}

private struct ProviderDriveRow: View {
    let descriptor: ProviderDriveDescriptor

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(descriptor.name)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if descriptor.isConfigured {
                Text("In Files")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            }

            if descriptor.isInMaintenance {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("In maintenance")
            }
        }
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts = ["Drive \(descriptor.driveID)"]
        if let role = descriptor.role {
            parts.append(role)
        }
        if descriptor.remoteDetailsAreAvailable == false {
            parts.append("Remote details unavailable")
        }
        return parts.joined(separator: " · ")
    }
}

private struct ProviderDriveManagementView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    let key: ProviderDriveKey
    @Environment(\.openURL) private var openURL

    @State private var isRemovalConfirmationPresented = false
    @State private var isStopSyncConfirmationPresented = false
    @State private var isOpenVaultPresented = false
    @State private var isForgetKeyPresented = false
    @State private var isRecoveryVerificationPresented = false
    @State private var isCloudRemovalConfirmationPresented = false
    @State private var isKnownFolderPreflightPresented = false

    var body: some View {
        Group {
            if model.account(accountIdentifier: key.accountIdentifier) == nil {
                ContentUnavailableView(
                    "Account Unavailable",
                    systemImage: "person.crop.circle.badge.exclamationmark",
                    description: Text("The account for this drive is no longer connected.")
                )
            } else if let descriptor {
                driveForm(descriptor)
            } else {
                ContentUnavailableView(
                    "Drive Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text("This drive is no longer available or configured.")
                )
            }
        }
        .navigationTitle(descriptor?.name ?? "Drive")
        .toolbar {
            ToolbarItem(placement: refreshToolbarPlacement) {
                Button {
                    Task { await model.loadDrives(accountIdentifier: key.accountIdentifier) }
                } label: {
                    Label("Refresh Drive Details", systemImage: "arrow.clockwise")
                }
                .disabled(model.canLoadDrives(for: key.accountIdentifier) == false || isBusy)
                .accessibilityIdentifier("drive.refresh")
            }
        }
        .confirmationDialog(
            "Remove \(descriptor?.name ?? "this drive") from Files?",
            isPresented: $isRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove from Files", role: .destructive) {
                guard let configuration = descriptor?.configuration else { return }
                Task { await model.removeDomain(configuration) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the File Provider domain, cached snapshots, activities, conflicts, and other provider-local state. Remote kDrive files are not deleted.")
        }
        .sheet(isPresented: vaultSetupBinding) {
            EncryptedVaultSetupFlow(model: model)
        }
        .sheet(isPresented: $isOpenVaultPresented) {
            if let drive = descriptor?.remote {
                VaultOpenView(
                    model: model,
                    accountIdentifier: key.accountIdentifier,
                    drive: drive
                )
            }
        }
        .sheet(isPresented: $isForgetKeyPresented) {
            if let configuration = descriptor?.encryptedConfiguration {
                VaultForgetKeyView(model: model, configuration: configuration)
            }
        }
        .sheet(isPresented: $isRecoveryVerificationPresented) {
            if let configuration = descriptor?.encryptedConfiguration {
                VaultRecoveryVerificationView(
                    model: model,
                    configuration: configuration
                )
            }
        }
        .confirmationDialog(
            "Remove this vault from iCloud Keychain?",
            isPresented: $isCloudRemovalConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove from iCloud Keychain", role: .destructive) {
                guard let configuration = descriptor?.encryptedConfiguration else {
                    return
                }
                Task {
                    await model.removeICloudKeychainAccess(for: configuration)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The synchronized record is removed globally. Keys already imported by another device remain usable; revoking a lost device requires a full vault rekey.")
        }
        #if os(macOS)
        .sheet(isPresented: $isKnownFolderPreflightPresented) {
            if let configuration = descriptor?.configuration {
                KnownFolderPreflightView(
                    model: model,
                    configuration: configuration
                )
            }
        }
        .confirmationDialog(
            "Stop syncing Desktop and Documents?",
            isPresented: $isStopSyncConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Stop Syncing", role: .destructive) {
                guard let configuration = descriptor?.configuration else { return }
                Task { await model.disableKnownFolderSync(for: configuration) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("macOS will stop replicating both folders with kDrive. Remote files in \(knownFolderRemotePath) are not deleted.")
        }
        #endif
    }

    private var descriptor: ProviderDriveDescriptor? {
        ProviderDriveDescriptor.merge(
            accountIdentifier: key.accountIdentifier,
            drives: model.drives(for: key.accountIdentifier),
            configurations: model.domains(for: key.accountIdentifier)
        ).first { $0.driveID == key.driveID }
    }

    private var activeAction: ProviderDriveAction? {
        model.activeDriveAction(for: key)
    }

    private var isBusy: Bool {
        activeAction != nil || model.isLoadingDrives(for: key.accountIdentifier)
    }

    private var vaultSetupBinding: Binding<Bool> {
        Binding(
            get: { model.vaultSetupStep != nil },
            set: { isPresented in
                if isPresented == false, model.vaultSetupStep != nil {
                    if model.pendingVaultProvisioning != nil {
                        Task { await model.cancelEncryptedVaultProvisioning() }
                    } else {
                        model.finishVaultSetup()
                    }
                }
            }
        )
    }

    private var knownFolderRemotePath: String {
        guard let configuration = descriptor?.configuration else {
            return "/Private/<this Mac>"
        }
        return model.knownFolderRemotePath(for: configuration)
    }

    private func driveForm(_ descriptor: ProviderDriveDescriptor) -> some View {
        List {
            Section("Drive") {
                LabeledContent("Name", value: descriptor.name)
                LabeledContent("Drive ID", value: String(descriptor.driveID))
                if let account = model.account(accountIdentifier: key.accountIdentifier) {
                    LabeledContent("Account", value: account.displayName)
                }
                if let role = descriptor.role {
                    LabeledContent("Role", value: role)
                }
                if let remoteStatus = descriptor.remoteStatus {
                    LabeledContent("Remote Status", value: remoteStatus)
                }
                if descriptor.remoteDetailsAreAvailable == false {
                    Label(
                        "Saved configuration · remote details are currently unavailable",
                        systemImage: "icloud.slash"
                    )
                    .foregroundStyle(.secondary)
                }
                if descriptor.isInMaintenance {
                    Label("This drive is currently in maintenance.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("Files") {
                LabeledContent("Availability") {
                    Text(descriptor.isConfigured ? "In Files" : "Not in Files")
                        .foregroundStyle(descriptor.isConfigured ? .green : .secondary)
                }

                if descriptor.encryptedConfiguration == nil, let remote = descriptor.remote {
                    if model.encryptedVaultICloudKeychainEnabled {
                        ForEach(model.cloudAccessCandidates(driveID: remote.id)) { candidate in
                            Button {
                                model.prepareOpenEncryptedVaultFromICloud(
                                    accountIdentifier: key.accountIdentifier,
                                    drive: remote,
                                    vaultID: candidate.vaultID
                                )
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Encrypted Vault Found in iCloud Keychain")
                                        Text(
                                            "\(candidate.vaultID.rawValue.uuidString.prefix(8)) · saved \(candidate.createdAt.formatted(date: .abbreviated, time: .shortened))"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "icloud.and.arrow.down")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy || model.encryptedVaultsEnabled == false)
                            .accessibilityIdentifier("drive.openICloudVault")
                        }

                        Button("Check iCloud Keychain Again", systemImage: "arrow.clockwise.icloud") {
                            Task { await model.refreshVaultAccessState() }
                        }
                        .disabled(isBusy)
                    }

                    Button {
                        Task {
                            await model.prepareEncryptedVault(
                                accountIdentifier: key.accountIdentifier,
                                drive: remote
                            )
                        }
                    } label: {
                        actionLabel(
                            title: "Create Encrypted Vault",
                            systemImage: "lock.square.stack",
                            action: .addingToFiles
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || model.encryptedVaultsEnabled == false)
                    .accessibilityIdentifier("drive.createEncryptedVault")

                    Button("Open Existing Vault", systemImage: "key.viewfinder") {
                        isOpenVaultPresented = true
                    }
                    .disabled(isBusy || model.encryptedVaultsEnabled == false)
                    .accessibilityIdentifier("drive.openEncryptedVault")

                    if model.encryptedVaultsEnabled == false {
                        Label(
                            "Encrypted vault creation is behind the security-review feature gate.",
                            systemImage: "checkmark.shield"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                if let configuration = descriptor.configuration {
                    LabeledContent(
                        "Storage",
                        value: storageDescription(for: configuration)
                    )
                    if configuration.encryptionMode == .opaqueVaultV1 {
                        Label(
                            "Experimental vault v1 is unsupported and is blocked from activation and mutation.",
                            systemImage: "lock.trianglebadge.exclamationmark"
                        )
                        .foregroundStyle(.red)
                    }
                    Button {
                        Task {
                            if let url = await model.userVisibleRootURL(for: configuration) {
                                openURL(url)
                            }
                        }
                    } label: {
                        #if os(macOS)
                        actionLabel(
                            title: "Show in Finder",
                            systemImage: "folder",
                            action: .showingInFiles
                        )
                        #else
                        actionLabel(
                            title: "Show in Files",
                            systemImage: "folder",
                            action: .showingInFiles
                        )
                        #endif
                    }
                    .disabled(
                        isBusy || configuration.encryptionMode == .opaqueVaultV1
                    )
                    .accessibilityIdentifier("drive.showInFiles")

                    Button {
                        Task { await model.syncNow(configuration) }
                    } label: {
                        actionLabel(
                            title: "Sync Now",
                            systemImage: "arrow.triangle.2.circlepath",
                            action: .syncingNow
                        )
                    }
                    .disabled(
                        isBusy || configuration.encryptionMode == .opaqueVaultV1
                    )
                    .accessibilityIdentifier("drive.syncNow")

                }
            }

            if let configuration = descriptor.encryptedConfiguration {
                securityRecoverySection(configuration)
            }

            if descriptor.legacyConfigurations.isEmpty == false {
                Section {
                    ForEach(descriptor.legacyConfigurations) { configuration in
                        Label(
                            "\(configuration.displayName) stores readable names, metadata, and contents on kDrive.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Legacy Plaintext Domains")
                } footer: {
                    Text("Safe cross-vault migration and destructive source purge are not implemented. Legacy domains remain separate.")
                }
            }

            #if os(macOS)
            if let configuration = descriptor.configuration,
               configuration.encryptionMode != .opaqueVaultV1 {
                knownFolderSection(configuration)
            }
            #endif

            if let statusMessage = model.statusMessage {
                Section {
                    ProviderFeedbackLabel(message: statusMessage)
                }
            }

            if descriptor.configuration != nil {
                Section {
                    Button("Remove from Files", role: .destructive) {
                        isRemovalConfirmationPresented = true
                    }
                    .disabled(isBusy)
                    .accessibilityIdentifier("drive.removeFromFiles")
                } footer: {
                    Text("Removing this drive clears its provider-local state but does not delete remote kDrive files.")
                }
            }
        }
    }

    @ViewBuilder
    private func actionLabel(
        title: String,
        systemImage: String,
        action: ProviderDriveAction
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if activeAction == action {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("\(title) in progress")
            }
        }
    }

    private func securityRecoverySection(
        _ configuration: ProviderDomainConfiguration
    ) -> some View {
        let localStatus = model.localKeyStatus(for: configuration)
        let cloudStatus = model.cloudAccessStatus(for: configuration)
        return Section {
            if model.vaultSetupNeedsAttention(for: configuration) {
                Button(
                    "Finish Vault Setup",
                    systemImage: "checklist"
                ) {
                    model.resumeVaultSetup(for: configuration)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("vault.resumeSetup")
            }

            LabeledContent("This Device", value: localKeyStatusTitle(localStatus))
            LabeledContent(
                "iCloud Keychain",
                value: cloudAccessStatusTitle(cloudStatus)
            )

            if model.encryptedVaultICloudKeychainEnabled {
                switch cloudStatus {
                case .disabled:
                    Button("Use iCloud Keychain", systemImage: "icloud") {
                        Task {
                            await model.enableICloudKeychainAccess(
                                for: configuration
                            )
                        }
                    }
                    .disabled(isBusy || localStatus != .available)
                case .available:
                    if localStatus != .available {
                        Button(
                            "Restore Key to This Device",
                            systemImage: "icloud.and.arrow.down"
                        ) {
                            Task {
                                await model.restoreVaultKeyFromICloud(
                                    for: configuration
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(
                        "Remove from iCloud Keychain",
                        systemImage: "icloud.slash",
                        role: .destructive
                    ) {
                        isCloudRemovalConfirmationPresented = true
                    }
                case .unavailable, .staleEpoch, .conflict:
                    Button("Check iCloud Keychain Again", systemImage: "arrow.clockwise.icloud") {
                        Task { await model.refreshVaultAccessState() }
                    }
                }
            } else {
                Label(
                    "iCloud Keychain convenience is behind a separate security-review gate.",
                    systemImage: "checkmark.shield"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Button("Verify Recovery Kit", systemImage: "checkmark.shield") {
                isRecoveryVerificationPresented = true
            }
            Button("Forget Key on This Device", systemImage: "key.slash") {
                isForgetKeyPresented = true
            }
            .disabled(isBusy || localStatus != .available)
        } header: {
            Text("Security & Recovery")
        } footer: {
            Text("The recovery kit remains the independent fallback. iCloud Keychain does not revoke keys already imported by other devices.")
        }
    }

    private func localKeyStatusTitle(_ status: VaultLocalKeyStatus) -> String {
        switch status {
        case .available:
            "Available"
        case .locked:
            "Unlock Device"
        case .missing:
            "Missing"
        case .invalid:
            "Invalid"
        }
    }

    private func cloudAccessStatusTitle(
        _ status: VaultCloudAccessStatus
    ) -> String {
        switch status {
        case .disabled:
            "Off"
        case .available:
            "Available"
        case .unavailable:
            "Unavailable"
        case .staleEpoch:
            "Update Required"
        case .conflict:
            "Conflict"
        }
    }

    private func storageDescription(
        for configuration: ProviderDomainConfiguration
    ) -> String {
        switch configuration.encryptionMode {
        case .legacyPlaintext:
            "Legacy plaintext domain"
        case .opaqueVaultV1:
            "Unsupported experimental encrypted vault v1"
        case .opaqueVaultV2:
            "End-to-end encrypted vault v2"
        }
    }

    #if os(macOS)
    private func knownFolderSection(_ configuration: ProviderDomainConfiguration) -> some View {
        let state = model.knownFolderSyncState(for: configuration)
        let remotePath = model.knownFolderRemotePath(for: configuration)
        let transferPhase = model.knownFolderTransferPhase(for: configuration)
        return Section {
            LabeledContent("Status", value: knownFolderStatusTitle(state))
            if transferPhase != .idle {
                LabeledContent(
                    "Transfer",
                    value: knownFolderTransferTitle(transferPhase)
                )
            }
            Text(knownFolderDetail(state, remotePath: remotePath))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            switch state {
            case .active, .partial:
                Button("Stop Syncing", role: .destructive) {
                    isStopSyncConfirmationPresented = true
                }
                .disabled(isBusy)
                .accessibilityIdentifier("drive.stopKnownFolders")
            case .inactive:
                Button {
                    Task {
                        await model.prepareKnownFolderSync(for: configuration)
                        isKnownFolderPreflightPresented = true
                    }
                } label: {
                    actionLabel(
                        title: "Sync Desktop & Documents",
                        systemImage: "desktopcomputer",
                        action: .enablingKnownFolders
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
                .accessibilityIdentifier("drive.enableKnownFolders")
            case .unavailable:
                Label("File Provider status unavailable", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Desktop & Documents")
        } footer: {
            Text(configuration.encryptionMode == .opaqueVaultV2
                ? "macOS manages both folders together. Their contents are encrypted before kDrive upload; Finder shows per-item transfer progress."
                : "macOS manages Desktop and Documents together under kDrive \(remotePath).")
        }
    }

    private func knownFolderTransferTitle(
        _ phase: KnownFolderTransferPhase
    ) -> String {
        switch phase {
        case .idle:
            "Not Started"
        case .preparing:
            "Preparing"
        case .awaitingConsent:
            "Awaiting macOS Consent"
        case .connectedUploading:
            "Connected · Uploading"
        case .upToDate:
            "Up to Date"
        case .quotaBlocked:
            "Quota Blocked"
        case .attentionRequired:
            "Attention Required"
        }
    }

    private func knownFolderStatusTitle(_ state: ProviderKnownFolderSyncState) -> String {
        switch state {
        case .active:
            "Syncing"
        case .partial:
            "Needs Repair"
        case .inactive:
            "Not Syncing"
        case .unavailable:
            "Unavailable"
        }
    }

    private func knownFolderDetail(
        _ state: ProviderKnownFolderSyncState,
        remotePath: String
    ) -> String {
        switch state {
        case .active:
            "Desktop and Documents sync with \(remotePath)/Desktop and \(remotePath)/Documents."
        case .partial:
            "Only part of the known-folder configuration is active. Stop syncing, then enable it again to repair the setup."
        case .inactive:
            "Sync both folders in this drive’s \(remotePath) directory."
        case .unavailable:
            "The live File Provider known-folder state could not be read."
        }
    }
    #endif

    private var refreshToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }
}

private struct ProviderFeedbackLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle")
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
    }
}

private struct ProviderSetupErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("kDrive")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: dismiss) {
                Label("Dismiss", systemImage: "xmark")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Dismiss kDrive message")
            .accessibilityIdentifier("setup.dismissError")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.errorBanner")
    }
}

private struct EncryptedVaultSetupFlow: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation = ""
    @State private var useICloudKeychain = false
    @State private var didRunKnownFolderPreflight = false
    @State private var riskWarningSecondsRemaining = Int(
        PotassiumProviderAppModel.encryptedVaultRiskWarningDelaySeconds
    )
    @State private var isPreparingVault = false

    var body: some View {
        NavigationStack {
            Form {
                setupContent
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task {
                            if model.pendingVaultProvisioning != nil {
                                await model.cancelEncryptedVaultProvisioning()
                            } else {
                                model.finishVaultSetup()
                            }
                            dismiss()
                        }
                    }
                    .disabled(isPreparingVault)
                }
                confirmationToolbar
            }
        }
        .interactiveDismissDisabled(model.vaultSetupStep != .complete)
        .frame(minWidth: 520, minHeight: 620)
        .task(id: model.vaultSetupStep) {
            guard model.vaultSetupStep == .unsupportedRiskWarning else {
                return
            }
            riskWarningSecondsRemaining = Int(
                PotassiumProviderAppModel.encryptedVaultRiskWarningDelaySeconds
            )
            while riskWarningSecondsRemaining > 0 {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                riskWarningSecondsRemaining -= 1
            }
        }
    }

    @ViewBuilder
    private var setupContent: some View {
        switch model.vaultSetupStep {
        case .unsupportedRiskWarning:
            Section("Unsupported Experimental Feature") {
                Label(
                    "Complete Data Loss Is Possible",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(.red)

                Text(
                    "Using this experimental encrypted-vault feature may result in complete and unrecoverable data loss."
                )
                Text(
                    "This feature is not supported by OpenCow, Infomaniak, Apple, OpenAI, or anyone else. No person or organization can promise recovery or provide support if it fails."
                )
                Text("If you decide to continue, you are entirely on your own.")
                    .fontWeight(.semibold)
                Text(
                    "On a new device, the app cannot independently prove that kDrive presented the newest vault history because no external history witness exists."
                )
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("vault.unsupportedRiskWarning")

            Section {
                if isPreparingVault {
                    HStack {
                        ProgressView()
                        Text("Preparing the encrypted vault…")
                    }
                } else if riskWarningSecondsRemaining > 0 {
                    Text(
                        "Continue is available in \(riskWarningSecondsRemaining) second\(riskWarningSecondsRemaining == 1 ? "" : "s")."
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("vault.unsupportedRiskCountdown")
                } else {
                    Text("You may continue only if you accept this risk without support.")
                        .foregroundStyle(.secondary)
                }
            }

        case .overview:
            Section("End-to-End Encryption") {
                Label(
                    "kDrive receives randomized authenticated ciphertext objects.",
                    systemImage: "lock.shield"
                )
                Label(
                    "Finder and Files show normal names, metadata, thumbnails, and contents after local decryption.",
                    systemImage: "folder"
                )
                Label(
                    "Plaintext remains on this trusted device and may be indexed by Spotlight.",
                    systemImage: "desktopcomputer"
                )
            }
            Section("What kDrive Can Still See") {
                Text("Vault presence, padded ciphertext sizes, object counts, server timestamps, request timing, access patterns, quota use, and deletion remain visible.")
                    .foregroundStyle(.secondary)
            }

        case .keyAccess:
            Section("Key Access") {
                Toggle(
                    "Also use iCloud Keychain",
                    isOn: $useICloudKeychain
                )
                .disabled(model.encryptedVaultICloudKeychainEnabled == false)
                Text(useICloudKeychain
                    ? "A separate end-to-end encrypted access record lets trusted Apple devices open this vault. Apple Account recovery and trusted-device security become part of the custody boundary."
                    : "The unwrapped vault key remains only in this device’s non-synchronizing Data Protection Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if model.encryptedVaultICloudKeychainEnabled == false {
                    Label(
                        "iCloud Keychain convenience is behind a separate security-review gate.",
                        systemImage: "checkmark.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            Section {
                Text("The offline recovery kit is required in both modes and is never placed in iCloud Keychain.")
            }

        case .recoveryKit:
            Section {
                if let kit = model.pendingVaultProvisioning?.recoveryKit.encoded {
                    VaultRecoveryQRCode(value: kit)
                        .frame(maxWidth: .infinity)
                    Text(kit)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("vault.recoveryKit")
                }
            } header: {
                Text("One-time Recovery Kit")
            } footer: {
                Text("Save this offline. It is never uploaded, logged, or automatically exported. Losing every device key and this kit makes the vault unrecoverable.")
            }
            Section("Confirm") {
                TextEditor(text: $confirmation)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 110)
                    .accessibilityIdentifier("vault.recoveryConfirmation")
                Text("Paste or scan the complete recovery kit to prove you saved it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .registering:
            Section {
                HStack {
                    ProgressView()
                    Text("Registering and authenticating the encrypted vault…")
                }
            }

        case .desktopDocuments:
            #if os(macOS)
            desktopDocumentsSetupContent
            #else
            Section {
                Text("Desktop and Documents uploaded by a Mac remain available in Files on this device.")
            }
            #endif

        case .complete:
            completionContent

        case nil:
            EmptyView()
        }
    }

    #if os(macOS)
    @ViewBuilder
    private var desktopDocumentsSetupContent: some View {
        Section("Protect Desktop & Documents") {
            Label(
                "macOS will hand both folders to this File Provider domain.",
                systemImage: "desktopcomputer"
            )
            Text("Each file is encrypted before kDrive upload. Existing copies held by iCloud Drive or another provider are not removed.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let configuration = model.vaultSetupOutcome.configuration,
               let preflight = model.knownFolderPreflight(for: configuration) {
                KnownFolderPreflightSummary(preflight: preflight)
            } else {
                HStack {
                    ProgressView()
                    Text("Checking ownership, vault unlock, and reachability…")
                }
            }

            Button("Protect Desktop & Documents", systemImage: "lock.desktopcomputer") {
                Task {
                    await model.configureDesktopDocumentsDuringSetup(enable: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled({
                guard let configuration = model.vaultSetupOutcome.configuration,
                      let preflight = model.knownFolderPreflight(for: configuration)
                else {
                    return true
                }
                return preflight.canRequestClaim == false
            }())

            Button("Not Now") {
                Task {
                    await model.configureDesktopDocumentsDuringSetup(enable: false)
                }
            }
        }
        .task {
            guard didRunKnownFolderPreflight == false,
                  let configuration = model.vaultSetupOutcome.configuration else {
                return
            }
            didRunKnownFolderPreflight = true
            await model.prepareKnownFolderSync(for: configuration)
        }
    }
    #endif

    @ViewBuilder
    private var completionContent: some View {
        Section("Vault Ready") {
            Label("Added to Finder and Files", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Label("Recovery kit verified", systemImage: "checkmark.shield")
            LabeledContent(
                "iCloud Keychain",
                value: cloudStatusTitle(
                    model.vaultSetupOutcome.cloudAccessStatus
                )
            )
            #if os(macOS)
            LabeledContent(
                "Desktop & Documents",
                value: model.vaultSetupOutcome.desktopDocumentsEnabled
                    ? "Connected"
                    : "Not Now"
            )
            #else
            Text("Desktop and Documents uploaded by a Mac are browsable in Files.")
                .foregroundStyle(.secondary)
            #endif
        }
        if model.vaultSetupOutcome.cloudAccessStatus == .unavailable {
            Section {
                Label(
                    "The vault remains valid. Retry iCloud Keychain later from Security & Recovery.",
                    systemImage: "icloud.slash"
                )
                .foregroundStyle(.orange)
            }
        }
    }

    @ToolbarContentBuilder
    private var confirmationToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            switch model.vaultSetupStep {
            case .unsupportedRiskWarning:
                Button("I Understand — Continue") {
                    isPreparingVault = true
                    Task {
                        await model.acceptEncryptedVaultRiskAndPrepare()
                        isPreparingVault = false
                    }
                }
                .disabled(riskWarningSecondsRemaining > 0 || isPreparingVault)
                .accessibilityIdentifier("vault.unsupportedRiskContinue")
            case .overview:
                Button("Continue") { model.setVaultSetupStep(.keyAccess) }
            case .keyAccess:
                Button("Continue") { model.setVaultSetupStep(.recoveryKit) }
            case .recoveryKit:
                Button("Create Vault") {
                    Task {
                        await model.confirmEncryptedVault(
                            recoveryKitConfirmation: confirmation,
                            useICloudKeychain: useICloudKeychain
                        )
                    }
                }
                .disabled(
                    confirmation.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            case .complete:
                Button("Done") {
                    model.finishVaultSetup()
                    dismiss()
                }
            case .registering, .desktopDocuments, nil:
                EmptyView()
            }
        }
    }

    private var navigationTitle: String {
        switch model.vaultSetupStep {
        case .unsupportedRiskWarning:
            "Unsupported — Data Loss Risk"
        case .overview:
            "Encrypted Vault"
        case .keyAccess:
            "Choose Key Access"
        case .recoveryKit:
            "Save Recovery Kit"
        case .registering:
            "Creating Vault"
        case .desktopDocuments:
            "Desktop & Documents"
        case .complete:
            "Setup Complete"
        case nil:
            "Encrypted Vault"
        }
    }

    private func cloudStatusTitle(_ status: VaultCloudAccessStatus) -> String {
        switch status {
        case .disabled:
            "Device Only"
        case .available:
            "Enabled"
        case .unavailable:
            "Needs Retry"
        case .staleEpoch:
            "Update Required"
        case .conflict:
            "Conflict"
        }
    }
}

private struct VaultOpenView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    let accountIdentifier: String
    let drive: KDriveDriveSummary

    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKit = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $recoveryKit)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                        .accessibilityIdentifier("vault.openRecoveryKit")
                } header: {
                    Text("Recovery Kit")
                } footer: {
                    Text("The kit is used locally to authenticate the bootstrap and checkpoint. It is not uploaded or saved.")
                }
            }
            .navigationTitle("Open Encrypted Vault")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open") {
                        model.prepareOpenEncryptedVault(
                            accountIdentifier: accountIdentifier,
                            drive: drive,
                            recoveryKitText: recoveryKit
                        )
                        if model.errorMessage == nil {
                            dismiss()
                        }
                    }
                    .disabled(recoveryKit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 360)
    }
}

private struct VaultRecoveryVerificationView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    let configuration: ProviderDomainConfiguration

    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKit = ""
    @State private var isVerifying = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $recoveryKit)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                } header: {
                    Text("Recovery Kit")
                } footer: {
                    Text("The kit authenticates the encrypted vault header locally. Recovery material is not sent, saved, or added to iCloud Keychain.")
                }
            }
            .navigationTitle("Verify Recovery Kit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verify") {
                        isVerifying = true
                        Task {
                            await model.verifyRecoveryKit(
                                for: configuration,
                                recoveryKitText: recoveryKit
                            )
                            isVerifying = false
                            if model.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        isVerifying || recoveryKit.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                }
            }
        }
        .frame(minWidth: 500, minHeight: 360)
    }
}

#if os(macOS)
private struct KnownFolderPreflightView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    let configuration: ProviderDomainConfiguration

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Desktop & Documents Preflight") {
                    if let preflight = model.knownFolderPreflight(
                        for: configuration
                    ) {
                        KnownFolderPreflightSummary(preflight: preflight)
                    } else {
                        HStack {
                            ProgressView()
                            Text("Checking ownership, unlock, and reachability…")
                        }
                    }
                }

                Section {
                    Text("macOS requests consent before moving both known folders. Potassium encrypts every new file revision before its kDrive upload.")
                    Text("Existing copies held by iCloud Drive or another provider are not removed.")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Protect Desktop & Documents")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let preflight = model.knownFolderPreflight(
                        for: configuration
                    ), preflight.canRequestClaim {
                        Button("Continue") {
                            Task {
                                await model.enableKnownFolderSync(
                                    for: configuration
                                )
                                if model.knownFolderSyncState(
                                    for: configuration
                                ) == .active {
                                    dismiss()
                                }
                            }
                        }
                    } else {
                        Button("Check Again") {
                            Task {
                                await model.prepareKnownFolderSync(
                                    for: configuration
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 430)
    }
}

private struct KnownFolderPreflightSummary: View {
    let preflight: KnownFolderPreflight

    var body: some View {
        LabeledContent(
            "Vault Key",
            value: preflight.vaultIsUnlocked ? "Available" : "Unlock Required"
        )
        LabeledContent(
            "kDrive",
            value: preflight.remoteIsReachable ? "Reachable" : "Unavailable"
        )
        LabeledContent("Available Quota", value: quotaTitle)
        LabeledContent("Current Owner", value: ownershipTitle)

        switch preflight.ownership {
        case .externalProvider(let displayName):
            Label(
                "\(displayName) may retain earlier server copies after macOS switches ownership.",
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.orange)
        case .legacyPotassium:
            Label(
                "Safe encrypted migration is not implemented. Keep the plaintext Potassium domain as owner.",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
            .foregroundStyle(.orange)
        case .partial:
            Label(
                "Stop the partial known-folder configuration before enabling both folders again.",
                systemImage: "wrench.and.screwdriver"
            )
            .foregroundStyle(.orange)
        case .none, .thisVault:
            EmptyView()
        }
    }

    private var quotaTitle: String {
        if let bytes = preflight.availableQuotaBytes {
            return ByteCountFormatter.string(
                fromByteCount: bytes,
                countStyle: .file
            )
        }
        return "Checked During Upload"
    }

    private var ownershipTitle: String {
        switch preflight.ownership {
        case .none:
            "Not Managed"
        case .thisVault:
            "This Encrypted Vault"
        case .legacyPotassium:
            "Legacy Potassium"
        case .externalProvider(let displayName), .partial(let displayName):
            displayName
        }
    }
}
#endif

private struct VaultForgetKeyView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    let configuration: ProviderDomainConfiguration

    @Environment(\.dismiss) private var dismiss
    @State private var recoveryKit = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $recoveryKit)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 150)
                } header: {
                    Text("Recovery Confirmation")
                } footer: {
                    Text("This deletes only the unwrapped vault key on this device. Domain removal, logout, and uninstall do not delete it.")
                }
            }
            .navigationTitle("Forget Vault Key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Forget Key", role: .destructive) {
                        Task {
                            await model.forgetVaultKey(
                                for: configuration,
                                recoveryKitConfirmation: recoveryKit
                            )
                            if model.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(recoveryKit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 360)
    }
}

private struct VaultRecoveryQRCode: View {
    let value: String

    var body: some View {
        if let image = Self.image(value) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 220, height: 220)
                .accessibilityLabel("Recovery kit QR code")
        }
    }

    private static func image(_ value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 8, y: 8)
        ) else {
            return nil
        }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(
            output,
            from: output.extent
        )
    }
}

private extension ProviderAccountAuthenticationKind {
    var title: String {
        switch self {
        case .oauth:
            "OAuth"
        case .manualAccessToken:
            "Manual Token"
        }
    }

    var systemImage: String {
        switch self {
        case .oauth:
            "person.crop.circle"
        case .manualAccessToken:
            "key"
        }
    }
}

extension View {
    func providerNavigationAnimation(animatesInitialAppearance: Bool = true) -> some View {
        modifier(ProviderNavigationAnimationModifier(
            animatesInitialAppearance: animatesInitialAppearance
        ))
    }
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
}

private struct ProviderNavigationAnimationModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let animatesInitialAppearance: Bool

    @State private var hasAppeared = false
    @State private var isVisible = false
    @State private var horizontalDirection: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(x: reduceMotion ? 0 : horizontalDirection * 28)
            .onAppear {
                let shouldAnimate = hasAppeared || animatesInitialAppearance
                hasAppeared = true

                if shouldAnimate {
                    withAnimation(navigationAnimation) {
                        isVisible = true
                        horizontalDirection = 0
                    }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        isVisible = true
                        horizontalDirection = 0
                    }
                }
            }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isVisible = false
                    horizontalDirection = -1
                }
            }
    }

    private var navigationAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.16)
            : .snappy(duration: 0.3, extraBounce: 0)
    }
}
