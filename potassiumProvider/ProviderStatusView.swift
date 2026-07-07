import Combine
import PotassiumProviderCore
import SwiftUI

struct ProviderStatusView: View {
    @ObservedObject var appModel: PotassiumProviderAppModel
    @StateObject private var statusModel: ProviderStatusViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let showSetup: () -> Void

    init(appModel: PotassiumProviderAppModel, showSetup: @escaping () -> Void) {
        self.appModel = appModel
        self.showSetup = showSetup
        _statusModel = StateObject(wrappedValue: ProviderStatusViewModel(
            snapshotStatisticsProvider: appModel.snapshotStatisticsProvider,
            eventStatisticsProvider: appModel.providerEventStatisticsProvider
        ))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if appModel.domains.isEmpty {
                        ProviderStatusEmptyView(showSetup: showSetup)
                            .transition(cardTransition)
                    }

                    ProviderStatusSummaryGrid(summary: statusModel.dashboard.summary)

                    if statusModel.dashboard.warnings.isEmpty == false {
                        ProviderStatusWarningList(warnings: statusModel.dashboard.warnings)
                            .transition(cardTransition)
                    }

                    if statusModel.dashboard.accounts.isEmpty == false {
                        ProviderStatusSectionHeader("Accounts")
                        VStack(spacing: 10) {
                            ForEach(statusModel.dashboard.accounts) { account in
                                ProviderStatusAccountRow(account: account)
                                    .transition(cardTransition)
                            }
                        }
                    }

                    if statusModel.dashboard.drives.isEmpty == false {
                        ProviderStatusSectionHeader("Drives")
                        VStack(spacing: 10) {
                            ForEach(statusModel.dashboard.drives) { drive in
                                ProviderStatusDriveCard(drive: drive)
                                    .transition(cardTransition)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 980, alignment: .leading)
            }
            .navigationTitle("Status")
            .toolbar {
                ToolbarItem(placement: refreshToolbarPlacement) {
                    Button {
                        Task { await statusModel.load(input: statusInput) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.pulse, value: statusModel.isLoading)
                    }
                    .disabled(statusModel.isLoading)
                    .accessibilityLabel("Refresh Status")
                }
            }
            .task(id: statusRefreshID) {
                await statusModel.load(input: statusInput)
            }
            .refreshable {
                await statusModel.load(input: statusInput)
            }
            .animation(reduceMotion ? .default : .snappy(duration: 0.28), value: statusModel.dashboard)
        }
    }

    private var statusInput: ProviderStatusInput {
        ProviderStatusInput(
            accounts: appModel.accounts,
            domains: appModel.domains,
            drivesByAccountIdentifier: appModel.drivesByAccountIdentifier,
            loadingDriveAccountIdentifiers: appModel.loadingDriveAccountIdentifiers
        )
    }

    private var statusRefreshID: String {
        var parts: [String] = []
        parts.append(appModel.accounts.map { "\($0.accountIdentifier):\($0.displayName):\($0.authenticationKind.rawValue)" }.joined(separator: ","))
        parts.append(appModel.domains.map { "\($0.domainIdentifier):\($0.accountIdentifier):\($0.driveID):\($0.displayName):\($0.driveName)" }.joined(separator: ","))
        parts.append(appModel.loadingDriveAccountIdentifiers.sorted().joined(separator: ","))
        parts.append(appModel.drivesByAccountIdentifier.keys.sorted().map { accountIdentifier in
            let drives = appModel.drivesByAccountIdentifier[accountIdentifier, default: []]
                .map { "\($0.id):\($0.name):\($0.role):\($0.status):\($0.isInMaintenance)" }
                .joined(separator: ",")
            return "\(accountIdentifier)=\(drives)"
        }.joined(separator: "|"))
        return parts.joined(separator: "#")
    }

    private var cardTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        )
    }

    private var refreshToolbarPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }
}

@MainActor
final class ProviderStatusViewModel: ObservableObject {
    @Published private(set) var dashboard = ProviderStatusDashboard.empty
    @Published private(set) var isLoading = false

    private let snapshotStatisticsProvider: (any KDriveSnapshotStatisticsProviding)?
    private let eventStatisticsProvider: (any KDriveProviderEventStatisticsProviding)?
    private var eventObservationTask: Task<Void, Never>?
    private var lastInput: ProviderStatusInput?

    init(
        snapshotStatisticsProvider: (any KDriveSnapshotStatisticsProviding)?,
        eventStatisticsProvider: (any KDriveProviderEventStatisticsProviding)?
    ) {
        self.snapshotStatisticsProvider = snapshotStatisticsProvider
        self.eventStatisticsProvider = eventStatisticsProvider

        if let eventObserver = eventStatisticsProvider as? any KDriveProviderEventObserving {
            eventObservationTask = Task { [weak self] in
                let changes = await eventObserver.eventChanges(pollInterval: 1)
                for await _ in changes {
                    await self?.reloadLastInput()
                }
            }
        }
    }

    deinit {
        eventObservationTask?.cancel()
    }

    func load(input: ProviderStatusInput) async {
        lastInput = input
        isLoading = true
        defer { isLoading = false }

        let domainIdentifiers = Set(input.domains.map(\.domainIdentifier))
        var warnings: [String] = []
        var snapshotStatistics: [KDriveSnapshotDomainStatistics] = []
        var eventStatistics: [KDriveProviderEventDomainStatistics] = []

        if let snapshotStatisticsProvider {
            do {
                snapshotStatistics = try await snapshotStatisticsProvider.snapshotStatistics(domainIdentifiers: domainIdentifiers)
            } catch {
                warnings.append("Snapshot statistics are unavailable.")
            }
        } else if input.domains.isEmpty == false {
            warnings.append("Snapshot statistics are unavailable.")
        }

        let eventDomainIdentifiers = domainIdentifiers.union([ProviderConstants.appActivityDomainIdentifier])
        if let eventStatisticsProvider {
            do {
                eventStatistics = try await eventStatisticsProvider.eventStatistics(domainIdentifiers: eventDomainIdentifiers)
            } catch {
                warnings.append("Activity statistics are unavailable.")
            }
        } else if input.domains.isEmpty == false {
            warnings.append("Activity statistics are unavailable.")
        }

        dashboard = ProviderStatusDashboard.make(
            input: input,
            snapshotStatistics: snapshotStatistics,
            eventStatistics: eventStatistics,
            warnings: warnings
        )
    }

    private func reloadLastInput() async {
        guard let lastInput else { return }
        await load(input: lastInput)
    }
}

struct ProviderStatusInput: Equatable {
    let accounts: [ProviderAccount]
    let domains: [ProviderDomainConfiguration]
    let drivesByAccountIdentifier: [String: [KDriveDriveSummary]]
    let loadingDriveAccountIdentifiers: Set<String>
}

struct ProviderStatusDashboard: Equatable {
    var summary: ProviderStatusSummary
    var accounts: [ProviderStatusAccount]
    var drives: [ProviderStatusDrive]
    var warnings: [String]

    static let empty = ProviderStatusDashboard(
        summary: ProviderStatusSummary(
            accountCount: 0,
            configuredDriveCount: 0,
            loadedDriveCount: 0,
            cachedSnapshotItemCount: 0,
            issueCount: 0,
            latestActivityAt: nil
        ),
        accounts: [],
        drives: [],
        warnings: []
    )

    static func make(
        input: ProviderStatusInput,
        snapshotStatistics: [KDriveSnapshotDomainStatistics],
        eventStatistics: [KDriveProviderEventDomainStatistics],
        warnings: [String]
    ) -> ProviderStatusDashboard {
        let accountsByIdentifier = Dictionary(uniqueKeysWithValues: input.accounts.map { ($0.accountIdentifier, $0) })
        let domainsByAccountIdentifier = Dictionary(grouping: input.domains, by: \.accountIdentifier)
        let snapshotStatisticsByDomain = Dictionary(uniqueKeysWithValues: snapshotStatistics.map { ($0.domainIdentifier, $0) })
        let eventStatisticsByDomain = Dictionary(uniqueKeysWithValues: eventStatistics.map { ($0.domainIdentifier, $0) })

        let accountRows = input.accounts.map { account in
            ProviderStatusAccount(
                accountIdentifier: account.accountIdentifier,
                displayName: account.displayName,
                authenticationKind: account.authenticationKind,
                configuredDriveCount: domainsByAccountIdentifier[account.accountIdentifier, default: []].count,
                loadedDriveCount: input.drivesByAccountIdentifier[account.accountIdentifier, default: []].count,
                isLoadingDrives: input.loadingDriveAccountIdentifiers.contains(account.accountIdentifier)
            )
        }

        let driveRows = input.domains
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            .map { domain in
                let loadedDrive = input.drivesByAccountIdentifier[domain.accountIdentifier, default: []]
                    .first { $0.id == domain.driveID }
                let snapshotStats = snapshotStatisticsByDomain[domain.domainIdentifier] ?? KDriveSnapshotDomainStatistics(domainIdentifier: domain.domainIdentifier)
                let eventStats = eventStatisticsByDomain[domain.domainIdentifier] ?? KDriveProviderEventDomainStatistics(domainIdentifier: domain.domainIdentifier)
                let accountName = accountsByIdentifier[domain.accountIdentifier]?.displayName ?? "Account"
                return ProviderStatusDrive(
                    domainIdentifier: domain.domainIdentifier,
                    accountIdentifier: domain.accountIdentifier,
                    accountName: accountName,
                    displayName: domain.displayName,
                    driveID: domain.driveID,
                    driveName: domain.driveName,
                    rootFileID: domain.rootFileID,
                    role: loadedDrive?.role,
                    status: loadedDrive?.status,
                    isInMaintenance: loadedDrive?.isInMaintenance ?? false,
                    snapshotContainerCount: snapshotStats.containerCount,
                    cachedSnapshotItemCount: snapshotStats.itemCount,
                    fullyEnumeratedContainerCount: snapshotStats.fullyEnumeratedContainerCount,
                    advancedListingContainerCount: snapshotStats.advancedListingContainerCount,
                    lastSnapshotUpdatedAt: snapshotStats.lastUpdatedAt,
                    unresolvedConflictCount: eventStats.unresolvedConflictCount,
                    blockedConflictCount: eventStats.blockedConflictCount,
                    failedConflictCount: eventStats.failedConflictCount,
                    resolvedConflictCount: eventStats.resolvedConflictCount,
                    recentFailureCount: eventStats.recentFailureCount,
                    recentSuccessCount: eventStats.recentSuccessCount,
                    latestConflictAt: eventStats.latestConflictAt,
                    latestActivityAt: eventStats.latestActivityAt
                )
            }

        let appEventStats = eventStatisticsByDomain[ProviderConstants.appActivityDomainIdentifier]
        let latestActivityAt = ([appEventStats?.latestActivityAt] + driveRows.map(\.latestActivityAt))
            .compactMap { $0 }
            .max()
        let issueCount = driveRows.reduce(appEventStats?.recentFailureCount ?? 0) { $0 + $1.issueCount }
        let cachedSnapshotItemCount = driveRows.reduce(0) { $0 + $1.cachedSnapshotItemCount }

        return ProviderStatusDashboard(
            summary: ProviderStatusSummary(
                accountCount: input.accounts.count,
                configuredDriveCount: input.domains.count,
                loadedDriveCount: input.drivesByAccountIdentifier.values.reduce(0) { $0 + $1.count },
                cachedSnapshotItemCount: cachedSnapshotItemCount,
                issueCount: issueCount,
                latestActivityAt: latestActivityAt
            ),
            accounts: accountRows,
            drives: driveRows,
            warnings: warnings
        )
    }
}

struct ProviderStatusSummary: Equatable {
    var accountCount: Int
    var configuredDriveCount: Int
    var loadedDriveCount: Int
    var cachedSnapshotItemCount: Int
    var issueCount: Int
    var latestActivityAt: Date?

    var healthScore: Double {
        guard configuredDriveCount > 0 else { return 0 }
        let issueBudget = max(1, configuredDriveCount * 3)
        return max(0, 1 - (Double(issueCount) / Double(issueBudget)))
    }
}

struct ProviderStatusAccount: Equatable, Identifiable {
    var id: String { accountIdentifier }

    let accountIdentifier: String
    let displayName: String
    let authenticationKind: ProviderAccountAuthenticationKind
    let configuredDriveCount: Int
    let loadedDriveCount: Int
    let isLoadingDrives: Bool

    var authenticationTitle: String {
        switch authenticationKind {
        case .oauth:
            return "OAuth"
        case .manualAccessToken:
            return "Manual Token"
        }
    }

    var systemImage: String {
        switch authenticationKind {
        case .oauth:
            return "person.crop.circle"
        case .manualAccessToken:
            return "key"
        }
    }
}

struct ProviderStatusDrive: Equatable, Identifiable {
    var id: String { domainIdentifier }

    let domainIdentifier: String
    let accountIdentifier: String
    let accountName: String
    let displayName: String
    let driveID: Int
    let driveName: String
    let rootFileID: Int
    let role: String?
    let status: String?
    let isInMaintenance: Bool
    let snapshotContainerCount: Int
    let cachedSnapshotItemCount: Int
    let fullyEnumeratedContainerCount: Int
    let advancedListingContainerCount: Int
    let lastSnapshotUpdatedAt: Date?
    let unresolvedConflictCount: Int
    let blockedConflictCount: Int
    let failedConflictCount: Int
    let resolvedConflictCount: Int
    let recentFailureCount: Int
    let recentSuccessCount: Int
    let latestConflictAt: Date?
    let latestActivityAt: Date?

    var issueCount: Int {
        unresolvedConflictCount + blockedConflictCount + failedConflictCount + recentFailureCount + (isInMaintenance ? 1 : 0)
    }

    var health: ProviderStatusDriveHealth {
        if issueCount > 0 { return .attention }
        if snapshotContainerCount == 0 && latestActivityAt == nil { return .quiet }
        return .ready
    }

    var remoteDetail: String {
        var parts = ["Drive \(driveID)"]
        if let role, role.isEmpty == false {
            parts.append(role)
        }
        if let status, status.isEmpty == false {
            parts.append(status)
        }
        if isInMaintenance {
            parts.append("Maintenance")
        }
        return parts.joined(separator: " · ")
    }
}

enum ProviderStatusDriveHealth {
    case ready
    case quiet
    case attention

    var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .quiet:
            return "Waiting"
        case .attention:
            return "Attention"
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            return "checkmark.circle"
        case .quiet:
            return "moon"
        case .attention:
            return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .ready:
            return .green
        case .quiet:
            return .secondary
        case .attention:
            return .orange
        }
    }
}

private struct ProviderStatusEmptyView: View {
    let showSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.tint)

            Text("No drives in Files yet")
                .font(.title2.weight(.semibold))

            Text("Add a kDrive from Setup to populate this status view.")
                .foregroundStyle(.secondary)

            Button(action: showSetup) {
                Label("Open Setup", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.borderedProminent)
        }
        .providerStatusCard()
    }
}

private struct ProviderStatusSummaryGrid: View {
    let summary: ProviderStatusSummary

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12, alignment: .top)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ProviderStatusMetricCard(title: "Accounts", value: summary.accountCount, systemImage: "person.2", tint: .blue)
            ProviderStatusMetricCard(title: "In Files", value: summary.configuredDriveCount, systemImage: "folder", tint: .green)
            ProviderStatusMetricCard(title: "Loaded", value: summary.loadedDriveCount, systemImage: "externaldrive", tint: .indigo)
            ProviderStatusMetricCard(title: "Cached Items", value: summary.cachedSnapshotItemCount, systemImage: "tray.full", tint: .teal)
            ProviderStatusMetricCard(title: "Issues", value: summary.issueCount, systemImage: summary.issueCount == 0 ? "checkmark.seal" : "exclamationmark.triangle", tint: summary.issueCount == 0 ? .green : .orange)
            ProviderStatusHealthCard(summary: summary)
            ProviderStatusLatestActivityCard(date: summary.latestActivityAt)
        }
    }
}

private struct ProviderStatusMetricCard: View {
    let title: String
    let value: Int
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, value: value)

            Text(value, format: .number)
                .font(.title.weight(.semibold))
                .contentTransition(.numericText())

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .providerStatusCard()
    }
}

private struct ProviderStatusHealthCard: View {
    let summary: ProviderStatusSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Gauge(value: summary.healthScore) {
                Label("Health", systemImage: "gauge.medium")
            } currentValueLabel: {
                Text(summary.healthScore, format: .percent.precision(.fractionLength(0)))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(summary.issueCount == 0 ? .green : .orange)

            Text("Health")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .providerStatusCard()
    }
}

private struct ProviderStatusLatestActivityCard: View {
    let date: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.purple)

            if let date {
                Text(date, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                    .contentTransition(.numericText())
            } else {
                Text("No Activity")
                    .font(.headline)
            }

            Text("Latest")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .providerStatusCard()
    }
}

private struct ProviderStatusWarningList: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .providerStatusCard()
    }
}

private struct ProviderStatusSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .padding(.top, 4)
    }
}

private struct ProviderStatusAccountRow: View {
    let account: ProviderStatusAccount

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: account.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, value: account.isLoadingDrives)

            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.headline)
                Text(account.authenticationTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProviderStatusMiniStat(title: "Drives", value: account.configuredDriveCount)
            ProviderStatusMiniStat(title: "Loaded", value: account.loadedDriveCount)

            if account.isLoadingDrives {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading Drives")
            }
        }
        .providerStatusCard()
    }
}

private struct ProviderStatusDriveCard: View {
    let drive: ProviderStatusDrive

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "externaldrive.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(drive.driveName)
                        .font(.headline)
                    Text("\(drive.displayName) · \(drive.accountName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(drive.remoteDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(drive.health.title, systemImage: drive.health.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(drive.health.tint)
                    .labelStyle(.titleAndIcon)
            }

            Divider()

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
                ProviderStatusMiniStat(title: "Containers", value: drive.snapshotContainerCount)
                ProviderStatusMiniStat(title: "Items", value: drive.cachedSnapshotItemCount)
                ProviderStatusMiniStat(title: "Full", value: drive.fullyEnumeratedContainerCount)
                ProviderStatusMiniStat(title: "Advanced", value: drive.advancedListingContainerCount)
                ProviderStatusMiniStat(title: "Failures", value: drive.recentFailureCount)
                ProviderStatusMiniStat(title: "Conflicts", value: drive.unresolvedConflictCount + drive.blockedConflictCount + drive.failedConflictCount)
            }

            HStack(spacing: 12) {
                if let lastSnapshotUpdatedAt = drive.lastSnapshotUpdatedAt {
                    Label {
                        Text(lastSnapshotUpdatedAt, format: .dateTime.month().day().hour().minute())
                    } icon: {
                        Image(systemName: "tray")
                    }
                }

                if let latestActivityAt = drive.latestActivityAt {
                    Label {
                        Text(latestActivityAt, format: .dateTime.month().day().hour().minute())
                    } icon: {
                        Image(systemName: "clock")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .providerStatusCard()
    }
}

private struct ProviderStatusMiniStat: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.headline)
                .contentTransition(.numericText())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 64, alignment: .leading)
    }
}

private extension View {
    func providerStatusCard() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }
    }
}
