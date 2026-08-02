import FileProvider
import Foundation
import PotassiumProviderCore
import UniformTypeIdentifiers

enum FileProviderItemUserInfoKey {
    static let isDirectory = "isDirectory"
    static let isFavorite = "isFavorite"
    static let isTrashed = "isTrashed"
    static let isRoot = "isRoot"
}

final class FileProviderItem: NSObject, NSFileProviderItemProtocol {
    let itemIdentifier: NSFileProviderItemIdentifier
    let parentItemIdentifier: NSFileProviderItemIdentifier
    let filename: String
    let contentType: UTType
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?
    let creationDate: Date?
    let contentModificationDate: Date?
    let capabilities: NSFileProviderItemCapabilities
    #if !os(macOS)
    let isTrashed: Bool
    #endif
    let isUploaded: Bool
    #if os(macOS)
    let contentPolicy: NSFileProviderContentPolicy
    #endif
    let userInfo: [AnyHashable: Any]?

    init(configuration: ProviderDomainConfiguration) {
        self.itemIdentifier = .rootContainer
        self.parentItemIdentifier = .rootContainer
        self.filename = configuration.displayName
        self.contentType = .folder
        if let vault = configuration.vault,
           configuration.encryptionMode == .opaqueVaultV2 {
            self.itemVersion = NSFileProviderItemVersion(
                contentVersion: VaultRevision(
                    hashing: Data("root-content:\(vault.vaultIdentifier.rawValue.uuidString)".utf8)
                ).data,
                metadataVersion: VaultRevision(
                    hashing: Data("root-metadata:\(configuration.displayName):\(vault.keyEpoch)".utf8)
                ).data
            )
        } else {
            self.itemVersion = NSFileProviderItemVersion(
                contentVersion: Data("root-\(configuration.rootFileID)".utf8),
                metadataVersion: Data(configuration.updatedAt.timeIntervalSince1970.description.utf8)
            )
        }
        self.documentSize = nil
        self.creationDate = configuration.createdAt
        self.contentModificationDate = configuration.updatedAt
        self.capabilities = [.allowsContentEnumerating, .allowsAddingSubItems, .allowsReading]
        #if !os(macOS)
        self.isTrashed = false
        #endif
        self.isUploaded = true
        #if os(macOS)
        self.contentPolicy = .downloadLazily
        #endif
        self.userInfo = [
            FileProviderItemUserInfoKey.isDirectory: true,
            FileProviderItemUserInfoKey.isFavorite: false,
            FileProviderItemUserInfoKey.isTrashed: false,
            FileProviderItemUserInfoKey.isRoot: true,
        ]
        super.init()
    }

    init(vaultItem: VaultItem) {
        self.itemIdentifier = NSFileProviderItemIdentifier(
            vaultItem.id.fileProviderIdentifier
        )
        self.parentItemIdentifier = vaultItem.isTrashed
            ? .trashContainer
            : vaultItem.parentID.map {
                NSFileProviderItemIdentifier($0.fileProviderIdentifier)
            } ?? .rootContainer
        self.filename = vaultItem.filename
        self.contentType = vaultItem.contentType
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: vaultItem.contentRevision.data,
            metadataVersion: vaultItem.metadataRevision.data
        )
        self.documentSize = vaultItem.isDirectory
            ? nil
            : NSNumber(value: vaultItem.plaintextSize)
        self.creationDate = vaultItem.createdAt
        self.contentModificationDate = vaultItem.modifiedAt
        #if !os(macOS)
        self.isTrashed = vaultItem.isTrashed
        #endif
        self.isUploaded = true
        #if os(macOS)
        self.contentPolicy = .downloadLazily
        #endif
        self.userInfo = [
            FileProviderItemUserInfoKey.isDirectory: vaultItem.isDirectory,
            FileProviderItemUserInfoKey.isFavorite: vaultItem.isFavorite,
            FileProviderItemUserInfoKey.isTrashed: vaultItem.isTrashed,
            FileProviderItemUserInfoKey.isRoot: false,
        ]

        if vaultItem.isTrashed {
            self.capabilities = [.allowsReading, .allowsDeleting]
        } else if vaultItem.isDirectory {
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsContentEnumerating,
                .allowsAddingSubItems,
                .allowsReading,
                .allowsRenaming,
                .allowsReparenting,
                .allowsTrashing,
                .allowsDeleting,
            ]
            #if !os(macOS)
            capabilities.insert(.allowsEvicting)
            #endif
            self.capabilities = capabilities
        } else {
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsTrashing,
                .allowsDeleting,
            ]
            #if !os(macOS)
            capabilities.insert(.allowsEvicting)
            #endif
            self.capabilities = capabilities
        }
        super.init()
    }

    init(
        remoteItem: KDriveRemoteItem,
        rootFileID: Int = ProviderConstants.defaultRootFileID,
        isTrashed: Bool = false
    ) {
        self.itemIdentifier = NSFileProviderItemIdentifier(KDriveItemIdentifier.item(remoteItem.id).rawValue)
        self.parentItemIdentifier = isTrashed
            ? .trashContainer
            : remoteItem.parentID == rootFileID
                ? .rootContainer
                : NSFileProviderItemIdentifier(KDriveItemIdentifier.item(remoteItem.parentID).rawValue)
        self.filename = remoteItem.name
        self.contentType = remoteItem.contentType
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: remoteItem.contentVersion,
            metadataVersion: remoteItem.metadataVersion
        )
        self.documentSize = remoteItem.size.map(NSNumber.init(value:))
        self.creationDate = remoteItem.createdAt
        self.contentModificationDate = remoteItem.modifiedAt
        #if !os(macOS)
        self.isTrashed = isTrashed
        #endif
        self.isUploaded = true
        #if os(macOS)
        self.contentPolicy = .downloadLazily
        #endif
        var userInfo: [AnyHashable: Any] = [
            FileProviderItemUserInfoKey.isDirectory: remoteItem.isDirectory,
            FileProviderItemUserInfoKey.isTrashed: isTrashed,
            FileProviderItemUserInfoKey.isRoot: false,
        ]
        if let isFavorite = remoteItem.isFavorite {
            userInfo[FileProviderItemUserInfoKey.isFavorite] = isFavorite
        }
        self.userInfo = userInfo

        if isTrashed {
            self.capabilities = [.allowsReading, .allowsDeleting]
        } else if remoteItem.isDirectory {
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsContentEnumerating,
                .allowsAddingSubItems,
                .allowsReading,
                .allowsRenaming,
                .allowsReparenting,
                .allowsTrashing,
                .allowsDeleting,
            ]
            #if !os(macOS)
            capabilities.insert(.allowsEvicting)
            #endif
            self.capabilities = capabilities
        } else {
            var capabilities: NSFileProviderItemCapabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsTrashing,
                .allowsDeleting,
            ]
            #if !os(macOS)
            capabilities.insert(.allowsEvicting)
            #endif
            self.capabilities = capabilities
        }

        super.init()
    }
}
