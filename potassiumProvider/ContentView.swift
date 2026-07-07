import PotassiumProviderCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @State private var accountPendingLogout: ProviderAccount?

    var body: some View {
        TabView {
            setupView
                .tabItem {
                    Label("Setup", systemImage: "externaldrive.connected.to.line.below")
                }

            ConflictLogView(eventStore: model.providerEventStore)
                .tabItem {
                    Label("Activities", systemImage: "clock.arrow.circlepath")
                }
        }
    }

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
                    configuration: configuredDomainsByDriveID[drive.id]
                ) {
                    Task {
                        await model.addDomain(
                            accountIdentifier: account.accountIdentifier,
                            drive: drive
                        )
                    }
                } remove: { configuration in
                    Task { await model.removeDomain(configuration) }
                }
            }

            ForEach(configuredDomainsWithoutLoadedDrive) { domain in
                DriveConfigurationRow(
                    driveID: domain.driveID,
                    driveName: domain.driveName,
                    detail: "Drive \(domain.driveID)",
                    configuration: domain
                ) {
                    Task { await model.addDomain(accountIdentifier: account.accountIdentifier) }
                } remove: { configuration in
                    Task { await model.removeDomain(configuration) }
                }
            }
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

private struct DriveConfigurationRow: View {
    let driveID: Int
    let driveName: String
    let detail: String
    let configuration: ProviderDomainConfiguration?
    let add: () -> Void
    let remove: (ProviderDomainConfiguration) -> Void

    var body: some View {
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
            } else {
                Button(action: add) {
                    Label("Use in Files", systemImage: "folder.badge.plus")
                }
                .labelStyle(.iconOnly)
            }
        }
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
