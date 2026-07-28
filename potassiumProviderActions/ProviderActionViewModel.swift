import Combine
import FileProvider
import Foundation
import PotassiumProviderCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class ProviderActionViewModel: ObservableObject {
    enum Mode: Equatable {
        case shareLink
        case versionHistory

        init?(actionIdentifier: String) {
            switch actionIdentifier {
            case ProviderContextActionIdentifier.shareLink:
                self = .shareLink
            case ProviderContextActionIdentifier.versionHistory:
                self = .versionHistory
            default:
                return nil
            }
        }
    }

    let mode: Mode
    let domainIdentifier: String
    let itemIdentifier: NSFileProviderItemIdentifier

    @Published private(set) var item: KDriveRemoteItem?
    @Published private(set) var vaultItem: VaultItem?
    @Published private(set) var shareLink: KDriveShareLinkSummary?
    @Published private(set) var versions: [KDriveFileVersionSummary] = []
    @Published private(set) var vaultVersions: [VaultVersion] = []
    @Published private(set) var hasMoreVersions = false
    @Published private(set) var isLoading = true
    @Published private(set) var isWorking = false
    @Published var configuration = KDriveShareLinkConfiguration()
    @Published var password = ""
    @Published var usesExpiration = false
    @Published var expirationDate = Date().addingTimeInterval(7 * 24 * 60 * 60)
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var initialLoadErrorMessage: String?

    private var runtime: ProviderActionRuntime?
    private var nextVersionPage = 1
    private let versionPageSize = 50

    init(
        mode: Mode,
        domainIdentifier: String,
        itemIdentifier: NSFileProviderItemIdentifier
    ) {
        self.mode = mode
        self.domainIdentifier = domainIdentifier
        self.itemIdentifier = itemIdentifier
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let runtime = try await ProviderActionRuntime.load(domainIdentifier: domainIdentifier)
            if let vault = runtime.encryptedVault {
                guard let identifier = VaultItemIdentifier(
                    fileProviderIdentifier: itemIdentifier.rawValue
                ) else {
                    throw ProviderActionRuntimeError.configurationUnavailable
                }
                _ = try await vault.synchronize()
                let item = try await vault.item(identifier)
                self.runtime = runtime
                self.vaultItem = item
                switch mode {
                case .shareLink:
                    throw EncryptedVaultError.unsupportedNativeSharing
                case .versionHistory:
                    vaultVersions = try await vault.versions(itemID: identifier)
                        .sorted { $0.modifiedAt > $1.modifiedAt }
                    hasMoreVersions = false
                }
                return
            }
            let parsedIdentifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
            guard let fileID = parsedIdentifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
                throw ProviderActionRuntimeError.configurationUnavailable
            }
            let item = try await runtime.remote.item(
                driveID: runtime.configuration.driveID,
                fileID: fileID
            )
            self.runtime = runtime
            self.item = item

            switch mode {
            case .shareLink:
                try await loadShareLink(runtime: runtime, fileID: fileID)
            case .versionHistory:
                try await loadNextVersionPage()
            }
        } catch {
            errorMessage = error.localizedDescription
            initialLoadErrorMessage = error.localizedDescription
            await recordFailure(error)
        }
    }

    func saveShareLink() async {
        guard let runtime, let item else { return }
        let requestConfiguration = currentConfiguration
        if requestConfiguration.isValid(
            preservingPasswordFor: shareLink?.configuration.access
        ) == false {
            errorMessage = KDriveContextActionError.passwordRequired.localizedDescription
            return
        }

        await performWork {
            let link: KDriveShareLinkSummary
            let createsLink = self.shareLink == nil
            if createsLink {
                link = try await runtime.actions.createShareLink(
                    driveID: runtime.configuration.driveID,
                    fileID: item.id,
                    configuration: requestConfiguration
                )
            } else {
                link = try await runtime.actions.updateShareLink(
                    driveID: runtime.configuration.driveID,
                    fileID: item.id,
                    configuration: requestConfiguration
                )
            }
            self.shareLink = link
            self.apply(link.configuration)
            self.password = ""
            self.message = createsLink ? "Created share link." : "Saved share-link settings."
            await self.record(
                kind: .shareLink,
                summary: "Updated kDrive share-link settings.",
                item: item
            )
            await self.signalParentAndWorkingSet(runtime: runtime, parentID: item.parentID)
        }
    }

    func deleteShareLink() async {
        guard let runtime, let item else { return }
        await performWork {
            try await runtime.actions.deleteShareLink(
                driveID: runtime.configuration.driveID,
                fileID: item.id
            )
            self.shareLink = nil
            self.configuration = KDriveShareLinkConfiguration()
            self.password = ""
            self.usesExpiration = false
            self.message = "Disabled share link."
            await self.record(
                kind: .shareLink,
                summary: "Disabled kDrive share link.",
                item: item
            )
            await self.signalParentAndWorkingSet(runtime: runtime, parentID: item.parentID)
        }
    }

    func loadNextVersionPage() async throws {
        guard let runtime, let item, hasMoreVersions || nextVersionPage == 1 else { return }
        let page = try await runtime.actions.fileVersions(
            driveID: runtime.configuration.driveID,
            fileID: item.id,
            page: nextVersionPage,
            pageSize: versionPageSize
        )
        let knownIDs = Set(versions.map(\.id))
        versions.append(contentsOf: page.versions.filter { knownIDs.contains($0.id) == false })
        versions.sort { $0.createdAt > $1.createdAt }
        hasMoreVersions = page.hasMore
        nextVersionPage = page.page + 1
    }

    func requestNextVersionPage() async {
        await performWork {
            try await self.loadNextVersionPage()
        }
    }

    func restore(_ version: KDriveFileVersionSummary) async {
        guard let runtime, let currentItem = item else { return }
        await performWork {
            let latestItem = try await runtime.remote.item(
                driveID: runtime.configuration.driveID,
                fileID: currentItem.id
            )
            let restoredItem = try await runtime.actions.restoreFileVersion(
                driveID: runtime.configuration.driveID,
                fileID: latestItem.id,
                versionID: version.id,
                destinationParentID: latestItem.parentID,
                name: KDriveRestoredCopyNaming.filename(
                    originalName: latestItem.name,
                    restoredAt: Date()
                )
            )
            self.message = "Restored \(restoredItem.name) as a new copy."
            await self.record(
                kind: .versionRestore,
                summary: "Restored a previous file version as a new copy.",
                item: restoredItem
            )
            await self.signalParentAndWorkingSet(runtime: runtime, parentID: restoredItem.parentID)
        }
    }

    func restore(_ version: VaultVersion) async {
        guard let runtime,
              let vault = runtime.encryptedVault,
              let currentItem = vaultItem else {
            return
        }
        await performWork {
            let restored = try await vault.restoreVersion(
                itemID: currentItem.id,
                contentRevision: version.contentRevision
            )
            self.vaultItem = restored
            self.vaultVersions = try await vault.versions(itemID: restored.id)
                .sorted { $0.modifiedAt > $1.modifiedAt }
            self.message = "Restored the authenticated encrypted version."
            try? await runtime.eventStore?.recordActivity(KDriveProviderActivityEvent(
                domainIdentifier: self.domainIdentifier,
                driveID: runtime.configuration.driveID,
                kind: .versionRestore,
                itemIdentifier: restored.id.fileProviderIdentifier,
                itemName: nil,
                itemPath: nil,
                summary: "Restored an encrypted logical version."
            ))
            await self.signalEncryptedParentAndWorkingSet(
                runtime: runtime,
                parentID: restored.parentID
            )
        }
    }

    func copyShareLink() {
        guard let url = shareLink?.url else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
        UIPasteboard.general.url = url
        #endif
        message = "Copied share link."
    }

    private var currentConfiguration: KDriveShareLinkConfiguration {
        var value = configuration
        value.password = value.access == .password ? password.nilIfEmpty : nil
        value.validUntil = usesExpiration ? expirationDate : nil
        return value
    }

    private func loadShareLink(runtime: ProviderActionRuntime, fileID: Int) async throws {
        let link = try await runtime.actions.shareLink(
            driveID: runtime.configuration.driveID,
            fileID: fileID
        )
        shareLink = link
        if let link {
            apply(link.configuration)
        }
    }

    private func apply(_ value: KDriveShareLinkConfiguration) {
        configuration = value
        usesExpiration = value.validUntil != nil
        if let validUntil = value.validUntil {
            expirationDate = validUntil
        }
    }

    private func performWork(_ operation: @escaping () async throws -> Void) async {
        guard isWorking == false else { return }
        isWorking = true
        errorMessage = nil
        message = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
            await recordFailure(error)
        }
    }

    private func signalParentAndWorkingSet(
        runtime: ProviderActionRuntime,
        parentID: Int
    ) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: runtime.configuration.domainIdentifier),
            displayName: runtime.configuration.displayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let parentIdentifier: NSFileProviderItemIdentifier = parentID == runtime.configuration.rootFileID
            ? .rootContainer
            : NSFileProviderItemIdentifier(KDriveItemIdentifier.item(parentID).rawValue)
        for identifier in [parentIdentifier, .workingSet] {
            await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: identifier) { _ in continuation.resume() }
            }
        }
    }

    private func signalEncryptedParentAndWorkingSet(
        runtime: ProviderActionRuntime,
        parentID: VaultItemIdentifier?
    ) async {
        let domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(rawValue: runtime.configuration.domainIdentifier),
            displayName: runtime.configuration.displayName
        )
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let parentIdentifier = parentID.map {
            NSFileProviderItemIdentifier($0.fileProviderIdentifier)
        } ?? .rootContainer
        for identifier in [parentIdentifier, .workingSet] {
            await withCheckedContinuation { continuation in
                manager.signalEnumerator(for: identifier) { _ in continuation.resume() }
            }
        }
    }

    private func record(
        kind: KDriveProviderActivityKind,
        summary: String,
        item: KDriveRemoteItem
    ) async {
        try? await runtime?.eventStore?.recordActivity(KDriveProviderActivityEvent(
            domainIdentifier: domainIdentifier,
            driveID: item.driveID,
            kind: kind,
            itemIdentifier: KDriveItemIdentifier.item(item.id).rawValue,
            itemName: item.name,
            itemPath: item.path,
            summary: summary
        ))
    }

    private func recordFailure(_ error: Error) async {
        guard let runtime, let eventStore = runtime.eventStore else { return }
        let nsError = error as NSError
        let apiRejection = KDriveRemoteErrorClassifier.apiRejection(from: error)
        let category: KDriveProviderActivityErrorCategory
        if error is ProviderActionRuntimeError || error is KDriveOAuthError {
            category = .authentication
        } else if nsError.domain == NSURLErrorDomain {
            category = .network
        } else if apiRejection != nil {
            category = .api
        } else {
            category = .unknown
        }
        let kind: KDriveProviderActivityKind = mode == .shareLink ? .shareLink : .versionRestore
        let summary = mode == .shareLink
            ? "Could not complete a kDrive share-link action."
            : "Could not complete a kDrive version-history action."
        try? await eventStore.recordActivity(KDriveProviderActivityEvent(
            domainIdentifier: domainIdentifier,
            driveID: runtime.configuration.driveID,
            kind: kind,
            outcome: .failure,
            severity: .error,
            itemIdentifier: vaultItem?.id.fileProviderIdentifier
                ?? item.map { KDriveItemIdentifier.item($0.id).rawValue },
            itemName: vaultItem == nil ? item?.name : nil,
            itemPath: vaultItem == nil ? item?.path : nil,
            summary: summary,
            diagnostic: KDriveProviderActivityErrorDiagnostic(
                errorCategory: category,
                underlyingErrorDomain: nsError.domain,
                underlyingErrorCode: nsError.code,
                diagnosticSummary: apiRejection?.diagnosticSummary
                    ?? "The contextual kDrive action failed."
            )
        ))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
