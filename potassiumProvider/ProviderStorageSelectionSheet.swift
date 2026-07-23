#if os(macOS)
import Foundation
import PotassiumProviderCore
import SwiftUI

enum ProviderStorageSelectionPurpose {
    case add(driveName: String)
    case move(driveName: String, currentStorageLocation: ProviderDomainStorageLocation)

    var title: String {
        switch self {
        case .add(let driveName):
            "Use \(driveName) in Files"
        case .move(let driveName, _):
            "Change Storage for \(driveName)"
        }
    }

    var explanation: String {
        switch self {
        case .add:
            "Choose where macOS stores this File Provider domain and its local files."
        case .move(_, let currentStorageLocation):
            "Currently stored on \(currentStorageLocation.userFacingTitle). Choose a new location."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .add:
            "Use in Files"
        case .move:
            "Change Storage"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .add:
            "add-domain-storage-sheet"
        case .move:
            "change-domain-storage-sheet"
        }
    }

    var currentStorageLocation: ProviderDomainStorageLocation? {
        if case .move(_, let currentStorageLocation) = self {
            return currentStorageLocation
        }
        return nil
    }

    var isMove: Bool {
        if case .move = self { return true }
        return false
    }
}

private enum ProviderStorageSelection: Hashable {
    case onThisMac
    case externalVolume
}

struct ProviderStorageSelectionSheet: View {
    let purpose: ProviderStorageSelectionPurpose
    let selectExternalVolume: @MainActor () async -> ProviderExternalVolume?
    let confirm: (ProviderExternalVolume?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection = ProviderStorageSelection.onThisMac
    @State private var externalVolume: ProviderExternalVolume?
    @State private var isSelectingExternalVolume = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Text(purpose.explanation)
                            .foregroundStyle(.secondary)

                        storageChoiceButton(
                            selection: .onThisMac,
                            title: "On This Mac",
                            detail: "Keep File Provider content on this Mac.",
                            systemImage: "internaldrive"
                        ) {
                            selection = .onThisMac
                        }
                        .accessibilityIdentifier("storage-location-on-this-mac")

                        storageChoiceButton(
                            selection: .externalVolume,
                            title: "External Drive",
                            detail: "Store File Provider content on an encrypted APFS drive.",
                            systemImage: "externaldrive"
                        ) {
                            chooseExternalVolume()
                        }
                        .accessibilityIdentifier("storage-location-external-drive")
                    } header: {
                        Text("Storage Location")
                    }

                    if selection == .externalVolume {
                        Section("External Drive") {
                            if isSelectingExternalVolume {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Inspecting drive…")
                                        .foregroundStyle(.secondary)
                                }
                            } else if let externalVolume {
                                externalVolumeDetails(externalVolume)
                                Button("Choose a Different Drive…") {
                                    chooseExternalVolume()
                                }
                                .accessibilityIdentifier("storage-location-choose-another-external-drive")
                            } else {
                                Text("No external drive selected.")
                                    .foregroundStyle(.secondary)
                                Button("Choose Drive…") {
                                    chooseExternalVolume()
                                }
                                .accessibilityIdentifier("storage-location-choose-external-drive")
                            }

                            Label(
                                "macOS chooses the folder it uses on the selected drive. Keep the drive connected whenever you use this kDrive.",
                                systemImage: "externaldrive.badge.exclamationmark"
                            )
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("storage-location-external-drive-warning")
                        }
                    }

                    if purpose.isMove {
                        Section("Before Changing Storage") {
                            Label(
                                "Changing storage recreates the local File Provider cache, so offline files may be downloaded again.",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            Label(
                                "If Desktop & Documents sync is enabled, macOS may ask for folder permission again.",
                                systemImage: "folder.badge.questionmark"
                            )
                        }
                        .accessibilityIdentifier("storage-change-consequences")
                    }
                }
                .formStyle(.grouped)

                Divider()

                HStack {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("storage-selection-cancel")

                    Spacer()

                    Button(purpose.confirmationTitle) {
                        confirm(selection == .externalVolume ? externalVolume : nil)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(canConfirm == false)
                    .accessibilityIdentifier("storage-selection-confirm")
                }
                .padding()
            }
            .navigationTitle(purpose.title)
        }
        .frame(minWidth: 540, minHeight: 500)
        .accessibilityIdentifier(purpose.accessibilityIdentifier)
    }

    private func storageChoiceButton(
        selection option: ProviderStorageSelection,
        title: String,
        detail: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: selection == option ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selection == option ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == option ? .isSelected : [])
    }

    @ViewBuilder
    private func externalVolumeDetails(_ volume: ProviderExternalVolume) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(volume.displayName, systemImage: "externaldrive.fill")
                .font(.headline)
            Text(capacityDescription(for: volume))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("storage-location-external-drive-capacity")

            switch volume.eligibility {
            case .eligible:
                Label("Eligible for File Provider storage", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("storage-location-external-drive-eligibility")
            case .ineligible(let reasons):
                VStack(alignment: .leading, spacing: 4) {
                    Label("This drive cannot be used", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                    ForEach(displayedUnsupportedReasons(reasons), id: \.self) { reason in
                        Text(reason.userFacingDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("storage-location-external-drive-eligibility")
            }
        }
    }

    private var canConfirm: Bool {
        switch selection {
        case .onThisMac:
            return purpose.currentStorageLocation != .onThisMac
        case .externalVolume:
            guard let externalVolume,
                  case .eligible = externalVolume.eligibility
            else {
                return false
            }
            if case .externalVolume(let currentUUID, _) = purpose.currentStorageLocation {
                return externalVolume.uuid != currentUUID
            }
            return true
        }
    }

    private func chooseExternalVolume() {
        selection = .externalVolume
        guard isSelectingExternalVolume == false else { return }
        isSelectingExternalVolume = true
        Task {
            let selectedVolume = await selectExternalVolume()
            if let selectedVolume {
                externalVolume = selectedVolume
            }
            isSelectingExternalVolume = false
        }
    }

    private func capacityDescription(for volume: ProviderExternalVolume) -> String {
        let formattedAvailable = volume.availableCapacity.map(formatByteCount)
        let formattedTotal = volume.totalCapacity.map(formatByteCount)
        switch (formattedAvailable, formattedTotal) {
        case let (available?, total?):
            return "\(available) available of \(total)"
        case let (available?, nil):
            return "\(available) available"
        case let (nil, total?):
            return "\(total) capacity"
        case (nil, nil):
            return "Capacity unavailable"
        }
    }

    private func formatByteCount(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    private func displayedUnsupportedReasons(
        _ reasons: Set<ProviderExternalVolumeUnsupportedReason>
    ) -> [ProviderExternalVolumeUnsupportedReason] {
        let displayReasons = reasons.isEmpty ? [.unknown] : Array(reasons)
        return displayReasons.sorted(by: { $0.rawValue < $1.rawValue })
    }
}
#endif
