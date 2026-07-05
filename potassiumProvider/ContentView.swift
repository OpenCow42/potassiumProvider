import PotassiumProviderCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: PotassiumProviderAppModel

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
                accountSection
                driveSection
                domainFormSection
                domainsSection

                if let statusMessage = model.statusMessage {
                    Section {
                        Label(statusMessage, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("potassiumProvider")
            .toolbar {
                ToolbarItem(placement: refreshToolbarPlacement) {
                    Button {
                        Task { await model.loadDrives() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.canLoadDrives == false)
                }
            }
            .alert("kDrive", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Label(
                    model.isConnected ? "Connected" : "Disconnected",
                    systemImage: model.isConnected ? "checkmark.seal.fill" : "xmark.seal"
                )
                Spacer()
                if model.isConnected {
                    Button(role: .destructive) {
                        Task { await model.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .labelStyle(.iconOnly)
                }
            }

            Button {
                Task { await model.connectWithOAuth() }
            } label: {
                Label(model.isConnecting ? "Connecting" : "Connect with Infomaniak", systemImage: "person.crop.circle.badge.checkmark")
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

    private var driveSection: some View {
        Section("kDrives") {
            if model.drives.isEmpty {
                Label("No drives loaded", systemImage: "externaldrive.badge.questionmark")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Drive", selection: $model.selectedDriveID) {
                    ForEach(model.drives) { drive in
                        Text(drive.name).tag(Optional(drive.id))
                    }
                }
            }

            Button {
                Task { await model.loadDrives() }
            } label: {
                Label(model.isLoadingDrives ? "Loading Drives" : "Load Drives", systemImage: "externaldrive.connected.to.line.below")
            }
            .disabled(model.canLoadDrives == false)
        }
    }

    private var domainFormSection: some View {
        Section("Domain") {
            TextField("Drive ID", text: $model.manualDriveID)
                .platformNumberEntry()
            TextField("Drive name", text: $model.manualDriveName)

            Button {
                Task { await model.addDomain() }
            } label: {
                Label("Add Domain", systemImage: "folder.badge.plus")
            }
            .disabled(model.canAddDomain == false)
        }
    }

    private var domainsSection: some View {
        Section("Provider Domains") {
            if model.domains.isEmpty {
                Label("No domains configured", systemImage: "folder")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.domains) { domain in
                    DomainConfigurationRow(configuration: domain) {
                        Task { await model.removeDomain(domain) }
                    }
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
}

private struct DomainConfigurationRow: View {
    let configuration: ProviderDomainConfiguration
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.displayName)
                    .font(.headline)
                Text("\(configuration.driveName) · Drive \(configuration.driveID)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: remove) {
                Label("Remove", systemImage: "trash")
            }
            .labelStyle(.iconOnly)
        }
    }
}

#Preview {
    ContentView(model: PotassiumProviderAppModel(
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
