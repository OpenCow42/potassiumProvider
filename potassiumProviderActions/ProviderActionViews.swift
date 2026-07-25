import PotassiumProviderCore
import SwiftUI

struct ProviderActionRootView: View {
    @ObservedObject var model: ProviderActionViewModel
    let complete: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView("Loading kDrive…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.initialLoadErrorMessage {
                    ContentUnavailableView(
                        "Action Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if let item = model.item {
                    switch model.mode {
                    case .shareLink:
                        ShareLinkActionView(model: model, item: item)
                    case .versionHistory:
                        VersionHistoryActionView(model: model, item: item)
                    }
                } else {
                    ContentUnavailableView(
                        "Action Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The selected item could not be loaded.")
                    )
                }
            }
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: complete)
                        .disabled(model.isLoading || model.isWorking)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 440)
    }

    private var navigationTitle: String {
        switch model.mode {
        case .shareLink:
            return "Share kDrive Link"
        case .versionHistory:
            return "Version History"
        }
    }
}

private struct ShareLinkActionView: View {
    @ObservedObject var model: ProviderActionViewModel
    let item: KDriveRemoteItem
    @State private var confirmsDeletion = false

    var body: some View {
        Form {
            Section {
                Label(item.name, systemImage: item.isDirectory ? "folder" : "doc")
                    .lineLimit(2)
            }

            if let link = model.shareLink {
                Section("Link") {
                    Text(link.url.absoluteString)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                    HStack {
                        Button("Copy Link") {
                            model.copyShareLink()
                        }
                        ShareLink(item: link.url) {
                            Label("Share…", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }

            Section("Access") {
                Picker("Access", selection: $model.configuration.access) {
                    Text("Public").tag(KDriveShareLinkConfiguration.Access.public)
                    Text("Password Protected").tag(KDriveShareLinkConfiguration.Access.password)
                }
                if model.configuration.access == .password {
                    SecureField(
                        model.shareLink == nil ? "Password" : "New password (leave blank to keep current)",
                        text: $model.password
                    )
                }
                Toggle("Allow downloads", isOn: $model.configuration.allowsDownload)
                Toggle("Allow comments", isOn: $model.configuration.allowsComments)
                Toggle("Expiration date", isOn: $model.usesExpiration)
                if model.usesExpiration {
                    DatePicker(
                        "Valid until",
                        selection: $model.expirationDate,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }

            statusSection

            Section {
                Button(model.shareLink == nil ? "Create Link" : "Save Changes") {
                    Task { await model.saveShareLink() }
                }
                .disabled(model.isWorking)

                if model.shareLink != nil {
                    Button("Disable Link", role: .destructive) {
                        confirmsDeletion = true
                    }
                    .disabled(model.isWorking)
                }
            }
        }
        .confirmationDialog(
            "Disable this share link?",
            isPresented: $confirmsDeletion,
            titleVisibility: .visible
        ) {
            Button("Disable Link", role: .destructive) {
                Task { await model.deleteShareLink() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone using the current URL will lose access.")
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if model.isWorking {
            Section {
                ProgressView()
            }
        } else if let error = model.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        } else if let message = model.message {
            Section {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct VersionHistoryActionView: View {
    @ObservedObject var model: ProviderActionViewModel
    let item: KDriveRemoteItem
    @State private var pendingRestore: KDriveFileVersionSummary?

    var body: some View {
        List {
            Section {
                Label(item.name, systemImage: "doc")
                    .lineLimit(2)
            }

            if model.versions.isEmpty {
                ContentUnavailableView(
                    "No Previous Versions",
                    systemImage: "clock",
                    description: Text("kDrive did not return any stored versions for this file.")
                )
            } else {
                Section("Versions") {
                    ForEach(model.versions) { version in
                        VersionRow(version: version) {
                            pendingRestore = version
                        }
                    }
                    if model.hasMoreVersions {
                        Button("Load More") {
                            Task { await model.requestNextVersionPage() }
                        }
                        .disabled(model.isWorking)
                    }
                }
            }

            if model.isWorking {
                ProgressView()
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let message = model.message {
                Label(message, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            "Restore this version as a new copy?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if $0 == false { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let version = pendingRestore {
                Button("Restore as Copy") {
                    pendingRestore = nil
                    Task { await model.restore(version) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
            }
        } message: {
            Text("The current file will not be overwritten.")
        }
    }
}

private struct VersionRow: View {
    let version: KDriveFileVersionSummary
    let restore: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(version.createdAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.headline)
                Text("\(version.editorDisplayName) · \(ByteCountFormatter.string(fromByteCount: Int64(version.size), countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", action: restore)
                .buttonStyle(.borderless)
        }
    }
}
