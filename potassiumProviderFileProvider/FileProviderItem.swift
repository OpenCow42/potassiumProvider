import FileProvider
import Foundation
import PotassiumProviderCore
import UniformTypeIdentifiers

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

    init(configuration: ProviderDomainConfiguration) {
        self.itemIdentifier = .rootContainer
        self.parentItemIdentifier = .rootContainer
        self.filename = configuration.displayName
        self.contentType = .folder
        self.itemVersion = NSFileProviderItemVersion(
            contentVersion: Data("root-\(configuration.rootFileID)".utf8),
            metadataVersion: Data(configuration.updatedAt.timeIntervalSince1970.description.utf8)
        )
        self.documentSize = nil
        self.creationDate = configuration.createdAt
        self.contentModificationDate = configuration.updatedAt
        self.capabilities = [.allowsContentEnumerating, .allowsAddingSubItems, .allowsReading]
        super.init()
    }

    init(remoteItem: KDriveRemoteItem, rootFileID: Int = ProviderConstants.defaultRootFileID) {
        self.itemIdentifier = NSFileProviderItemIdentifier(KDriveItemIdentifier.item(remoteItem.id).rawValue)
        self.parentItemIdentifier = remoteItem.parentID == rootFileID
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

        if remoteItem.isDirectory {
            self.capabilities = [
                .allowsContentEnumerating,
                .allowsAddingSubItems,
                .allowsReading,
                .allowsRenaming,
                .allowsReparenting,
                .allowsTrashing,
                .allowsDeleting
            ]
        } else {
            self.capabilities = [
                .allowsReading,
                .allowsWriting,
                .allowsRenaming,
                .allowsReparenting,
                .allowsTrashing,
                .allowsDeleting
            ]
        }

        super.init()
    }
}
