#if os(macOS) && STABILITY
import PotassiumProviderCore
import SwiftUI

struct StabilityLabView: View {
    @ObservedObject var model: PotassiumProviderAppModel
    @State private var selectedAccountIdentifier: String?
    @State private var selectedDriveID: Int?
    @State private var resetConfirmation = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    introduction
                    isolationState
                    if model.stabilityLabConfiguration == nil {
                        provisioning
                    } else {
                        verificationAndReset
                        runControls
                    }
                    feedback
                }
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(28)
            }
            .navigationTitle("Stability Lab")
            .task { await prepareSelection() }
        }
    }

    private var introduction: some View {
        GroupBox("Disposable development root") {
            VStack(alignment: .leading, spacing: 8) {
                Text("This opt-in lab uses the existing manual-token Keychain flow and registers one verified, top-level plaintext folder—not the drive root.")
                Text("Use only a dedicated development account containing no customer data. Live checks and Finder mutations remain outside CI.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isolationState: some View {
        GroupBox("Isolation gate") {
            VStack(alignment: .leading, spacing: 8) {
                if model.domains.contains(where: { $0.purpose == .ordinary }) {
                    Label("Ordinary saved domains are present. Provisioning and reset are blocked.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Run scripts/uninstall-file-provider.sh --dry-run, inspect the plan, then use the explicit safe --yes cleanup. The lab never invokes hard purge.")
                        .foregroundStyle(.secondary)
                } else {
                    Label("No ordinary saved domain is visible to this build.", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var provisioning: some View {
        GroupBox("Provision") {
            VStack(alignment: .leading, spacing: 12) {
                if model.accounts.isEmpty {
                    Text("Add the dedicated development account in Setup, using the existing manual-token flow, then return here.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Account", selection: $selectedAccountIdentifier) {
                        Text("Choose an account").tag(String?.none)
                        ForEach(model.accounts) { account in
                            Text(account.displayName).tag(String?.some(account.accountIdentifier))
                        }
                    }
                    Picker("Internal drive", selection: $selectedDriveID) {
                        Text("Choose a drive").tag(Int?.none)
                        ForEach(selectedDrives) { drive in
                            Text(drive.name).tag(Int?.some(drive.id))
                        }
                    }

                    HStack {
                        Button("Refresh drives") {
                            guard let selectedAccountIdentifier else { return }
                            Task {
                                await model.loadDrives(accountIdentifier: selectedAccountIdentifier)
                                normalizeDriveSelection()
                            }
                        }
                        Button("Provision verified lab root") {
                            guard let selectedAccountIdentifier,
                                  let drive = selectedDrive else { return }
                            Task {
                                await model.provisionStabilityLab(
                                    accountIdentifier: selectedAccountIdentifier,
                                    drive: drive
                                )
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            selectedDrive == nil ||
                            model.isPerformingStabilityLabOperation ||
                            model.domains.isEmpty == false
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verificationAndReset: some View {
        GroupBox("Verify and reset") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Every verification reloads server-authoritative root and marker metadata. Reset additionally revalidates them and each immediate child's parent before moving that child to trash.")
                    .foregroundStyle(.secondary)

                Button("Verify lab safety gates") {
                    Task { await model.verifyStabilityLab() }
                }
                .disabled(model.isPerformingStabilityLabOperation)

                Divider()
                Text("Reset preserves both the lab root and its ownership marker. It never permanently deletes remote items.")
                Text("Type: \(StabilityLabResetConfirmation.requiredPhrase)")
                    .font(.callout.monospaced())
                TextField("Exact reset confirmation", text: $resetConfirmation)
                    .textFieldStyle(.roundedBorder)
                Button("Move verified lab contents to Trash", role: .destructive) {
                    let phrase = resetConfirmation
                    resetConfirmation = ""
                    Task { await model.resetStabilityLab(typedConfirmation: phrase) }
                }
                .disabled(
                    resetConfirmation != StabilityLabResetConfirmation.requiredPhrase ||
                    model.isPerformingStabilityLabOperation ||
                    model.activeStabilityRunID != nil
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var runControls: some View {
        GroupBox("Diagnostic run") {
            HStack {
                if model.activeStabilityRunID == nil {
                    Button("Verify and start run") {
                        Task { await model.startStabilityRun() }
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("Run active", systemImage: "record.circle")
                        .foregroundStyle(.red)
                    Button("Finish and seal run") {
                        Task { await model.finishStabilityRun() }
                    }
                }
            }
            .disabled(model.isPerformingStabilityLabOperation)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.errorMessage {
            Label(error, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        } else if let status = model.statusMessage {
            Label(status, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
        }
        if model.isPerformingStabilityLabOperation {
            ProgressView("Checking Stability Lab safety state…")
        }
    }

    private var selectedDrives: [KDriveDriveSummary] {
        guard let selectedAccountIdentifier else { return [] }
        return model.drives(for: selectedAccountIdentifier).filter(\.isUsableInternalDrive)
    }

    private var selectedDrive: KDriveDriveSummary? {
        selectedDrives.first { $0.id == selectedDriveID }
    }

    @MainActor
    private func prepareSelection() async {
        if selectedAccountIdentifier == nil {
            selectedAccountIdentifier = model.accounts.first?.accountIdentifier
        }
        if let selectedAccountIdentifier {
            await model.loadDrives(accountIdentifier: selectedAccountIdentifier)
        }
        normalizeDriveSelection()
    }

    private func normalizeDriveSelection() {
        if selectedDrives.contains(where: { $0.id == selectedDriveID }) == false {
            selectedDriveID = selectedDrives.first?.id
        }
    }
}
#endif
