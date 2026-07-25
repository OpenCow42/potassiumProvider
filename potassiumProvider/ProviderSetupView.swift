import PotassiumProviderCore
import SwiftUI

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
    let configuration: ProviderDomainConfiguration?

    var name: String {
        remote?.name ?? configuration?.driveName ?? "kDrive \(driveID)"
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
        configuration != nil
    }

    var remoteDetailsAreAvailable: Bool {
        remote != nil
    }

    static func merge(
        accountIdentifier: String,
        drives: [KDriveDriveSummary],
        configurations: [ProviderDomainConfiguration]
    ) -> [ProviderDriveDescriptor] {
        var configurationsByDriveID: [Int: ProviderDomainConfiguration] = [:]
        for configuration in configurations where configurationsByDriveID[configuration.driveID] == nil {
            configurationsByDriveID[configuration.driveID] = configuration
        }

        var seenDriveIDs: Set<Int> = []
        var descriptors = drives.compactMap { drive -> ProviderDriveDescriptor? in
            guard seenDriveIDs.insert(drive.id).inserted else { return nil }
            return ProviderDriveDescriptor(
                accountIdentifier: accountIdentifier,
                driveID: drive.id,
                remote: drive,
                configuration: configurationsByDriveID[drive.id]
            )
        }

        descriptors.append(contentsOf: configurations
            .filter { seenDriveIDs.insert($0.driveID).inserted }
            .map {
                ProviderDriveDescriptor(
                    accountIdentifier: accountIdentifier,
                    driveID: $0.driveID,
                    remote: nil,
                    configuration: $0
                )
            })
        return descriptors
    }
}

struct ProviderSetupView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @State private var path: [ProviderSetupRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            accountList
                .navigationDestination(for: ProviderSetupRoute.self) { route in
                    destination(for: route)
                }
        }
        .alert("kDrive", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
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

            Section("Accounts") {
                if model.accounts.isEmpty {
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

            if let statusMessage = model.statusMessage {
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
                .disabled(model.accounts.isEmpty || model.loadingDriveAccountIdentifiers.isEmpty == false)
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

    private var errorBinding: Binding<Bool> {
        Binding {
            model.errorMessage != nil
        } set: { isPresented in
            if isPresented == false {
                model.errorMessage = nil
            }
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
        #if os(macOS)
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
            Text("macOS will stop replicating both folders with kDrive. Remote files in /private are not deleted.")
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

                if descriptor.configuration == nil, let remote = descriptor.remote {
                    Button {
                        Task {
                            await model.addDomain(
                                accountIdentifier: key.accountIdentifier,
                                drive: remote
                            )
                        }
                    } label: {
                        actionLabel(
                            title: "Add to Files",
                            systemImage: "folder.badge.plus",
                            action: .addingToFiles
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                    .accessibilityIdentifier("drive.addToFiles")
                }

                if let configuration = descriptor.configuration {
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
                    .disabled(isBusy)
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
                    .disabled(isBusy)
                    .accessibilityIdentifier("drive.syncNow")
                }
            }

            #if os(macOS)
            if let configuration = descriptor.configuration {
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

    #if os(macOS)
    private func knownFolderSection(_ configuration: ProviderDomainConfiguration) -> some View {
        let state = model.knownFolderSyncState(for: configuration)
        return Section {
            LabeledContent("Status", value: knownFolderStatusTitle(state))
            Text(knownFolderDetail(state))
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
                    Task { await model.enableKnownFolderSync(for: configuration) }
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
            Text("macOS manages Desktop and Documents together under kDrive /private.")
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

    private func knownFolderDetail(_ state: ProviderKnownFolderSyncState) -> String {
        switch state {
        case .active:
            "Desktop and Documents sync with /private/Desktop and /private/Documents."
        case .partial:
            "Only part of the known-folder configuration is active. Stop syncing, then enable it again to repair the setup."
        case .inactive:
            "Sync both folders with this drive’s existing /private directory."
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

private extension View {
    func providerNavigationAnimation(animatesInitialAppearance: Bool = true) -> some View {
        modifier(ProviderNavigationAnimationModifier(
            animatesInitialAppearance: animatesInitialAppearance
        ))
    }

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
