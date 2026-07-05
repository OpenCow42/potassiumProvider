import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore
import UIKit
import UniformTypeIdentifiers

public final class PotassiumFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let manager: NSFileProviderManager
    private let temporaryDirectoryURL: URL

    var fileProviderDomain: NSFileProviderDomain {
        domain
    }

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.manager = NSFileProviderManager(for: domain)!
        self.temporaryDirectoryURL = (try? manager.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        super.init()
        FileProviderLog.replicatedExtension.info("init replicated extension for domain(\(self.domain.identifier.rawValue, privacy: .public)) displayName(\(self.domain.displayName, privacy: .private)) temporaryDirectory(\(self.temporaryDirectoryURL.path, privacy: .private))")
    }

    public func invalidate() {
        FileProviderLog.replicatedExtension.debug("invalidate replicated extension for domain(\(self.domain.identifier.rawValue, privacy: .public))")
    }

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        FileProviderLog.replicatedExtension.debug("item(forIdentifier:\(identifier.rawValue, privacy: .public)) domain(\(self.domain.identifier.rawValue, privacy: .public)) @ domainVersion(\(request.logDomainVersion, privacy: .public))")
        return Progress.cancellable {
            FileProviderLog.replicatedExtension.debug("cancel item(forIdentifier:\(identifier.rawValue, privacy: .public))")
            completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                if identifier == .rootContainer {
                    FileProviderLog.replicatedExtension.debug("resolved root item for domain(\(runtime.configuration.domainIdentifier, privacy: .public)) driveID(\(runtime.configuration.driveID, privacy: .public))")
                    completionHandler(FileProviderItem(configuration: runtime.configuration), nil)
                    return
                }

                let itemIdentifier = try KDriveItemIdentifier(rawValue: identifier.rawValue)
                guard let fileID = itemIdentifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let item = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                FileProviderLog.replicatedExtension.debug("resolved item identifier(\(identifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) type(\(item.type ?? "unknown", privacy: .public))")
                completionHandler(FileProviderItem(remoteItem: item, rootFileID: runtime.configuration.rootFileID), nil)
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.replicatedExtension.error("item(forIdentifier:\(identifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(nil, mappedError)
            }
        }
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        FileProviderLog.replicatedExtension.debug("fetchContents(for:\(itemIdentifier.rawValue, privacy: .public)) requestedVersion(\(logVersionDescription(requestedVersion), privacy: .public)) @ domainVersion(\(request.logDomainVersion, privacy: .public))")
        return Progress.cancellable {
            FileProviderLog.replicatedExtension.debug("cancel fetchContents(for:\(itemIdentifier.rawValue, privacy: .public))")
            completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
                guard let fileID = identifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let data = try await runtime.remote.downloadFile(driveID: runtime.configuration.driveID, fileID: fileID)
                let item = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                let temporaryURL = self.temporaryDirectoryURL
                    .appendingPathComponent("download-\(UUID().uuidString)")
                    .appendingPathExtension((item.name as NSString).pathExtension)
                try data.write(to: temporaryURL, options: [.atomic])
                FileProviderLog.replicatedExtension.info("fetched contents for item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) bytes(\(data.count, privacy: .public))")
                completionHandler(temporaryURL, FileProviderItem(remoteItem: item, rootFileID: runtime.configuration.rootFileID), nil)
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.replicatedExtension.error("fetchContents(for:\(itemIdentifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, mappedError)
            }
        }
    }

    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let fieldsDescription = String(describing: fields)
        let kind = itemTemplate.contentType?.conforms(to: .folder) == true ? "folder" : "file"
        FileProviderLog.replicatedExtension.debug("createItem(kind:\(kind, privacy: .public) parentIdentifier:\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public)) filename(\(itemTemplate.filename, privacy: .private)) fields(\(fieldsDescription, privacy: .public)) hasContents(\(url != nil, privacy: .public)) @ domainVersion(\(request.logDomainVersion, privacy: .public))")
        return Progress.cancellable {
            FileProviderLog.replicatedExtension.debug("cancel createItem(parentIdentifier:\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public))")
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                let parentID = try self.fileID(forParentIdentifier: itemTemplate.parentItemIdentifier, runtime: runtime)
                let createdItem: KDriveRemoteItem

                if itemTemplate.contentType?.conforms(to: .folder) == true {
                    createdItem = try await runtime.remote.createDirectory(
                        driveID: runtime.configuration.driveID,
                        parentID: parentID,
                        name: itemTemplate.filename
                    )
                } else {
                    let contents = try url.map { try Data(contentsOf: $0) } ?? Data()
                    FileProviderLog.replicatedExtension.debug("upload new file parentFileID(\(parentID, privacy: .public)) bytes(\(contents.count, privacy: .public))")
                    createdItem = try await runtime.remote.uploadFile(
                        driveID: runtime.configuration.driveID,
                        parentID: parentID,
                        fileName: itemTemplate.filename,
                        contents: contents,
                        lastModifiedAt: itemTemplate.contentModificationDate ?? nil,
                        conflictStrategy: .version
                    )
                }

                FileProviderLog.replicatedExtension.info("created \(kind, privacy: .public) item(\(createdItem.id, privacy: .public)) parentFileID(\(createdItem.parentID, privacy: .public)) driveID(\(runtime.configuration.driveID, privacy: .public))")
                completionHandler(FileProviderItem(remoteItem: createdItem, rootFileID: runtime.configuration.rootFileID), [], false, nil)
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.replicatedExtension.error("createItem(parentIdentifier:\(itemTemplate.parentItemIdentifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, mappedError)
            }
        }
    }

    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let fieldsDescription = String(describing: changedFields)
        let optionsDescription = String(describing: options)
        FileProviderLog.replicatedExtension.debug("modifyItem(\(item.itemIdentifier.rawValue, privacy: .public)) fields(\(fieldsDescription, privacy: .public)) options(\(optionsDescription, privacy: .public)) baseVersion(\(logVersionDescription(version), privacy: .public)) @ domainVersion(\(request.logDomainVersion, privacy: .public))")
        return Progress.cancellable {
            FileProviderLog.replicatedExtension.debug("cancel modifyItem(\(item.itemIdentifier.rawValue, privacy: .public))")
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                let identifier = try KDriveItemIdentifier(rawValue: item.itemIdentifier.rawValue)
                guard let fileID = identifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let latestItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)

                if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
                    guard KDriveVersionConflictResolver.itemVersionMatches(
                        contentVersion: version.contentVersion,
                        metadataVersion: version.metadataVersion,
                        remoteItem: latestItem
                    ) else {
                        throw self.staleVersionError()
                    }
                    FileProviderLog.replicatedExtension.info("trash item(\(item.itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public))")
                    try await runtime.remote.trashItem(driveID: runtime.configuration.driveID, fileID: fileID)
                    completionHandler(nil, [], false, nil)
                    return
                }

                let updatedItem: KDriveRemoteItem
                if let newContents, changedFields.contains(.contents) {
                    let data = try Data(contentsOf: newContents)
                    guard KDriveVersionConflictResolver.contentMatches(baseVersion: version.contentVersion, remoteItem: latestItem) else {
                        let conflictItem = try await self.uploadConflictCopy(
                            contents: data,
                            localItem: item,
                            latestItem: latestItem,
                            runtime: runtime
                        )
                        FileProviderLog.replicatedExtension.info("preserved stale content edit as conflict item(\(conflictItem.id, privacy: .public)) original(\(fileID, privacy: .public))")
                        completionHandler(FileProviderItem(remoteItem: conflictItem, rootFileID: runtime.configuration.rootFileID), [], false, nil)
                        return
                    }
                    FileProviderLog.replicatedExtension.debug("replace contents for item(\(item.itemIdentifier.rawValue, privacy: .public)) bytes(\(data.count, privacy: .public))")
                    updatedItem = try await runtime.remote.replaceFile(
                        driveID: runtime.configuration.driveID,
                        fileID: fileID,
                        contents: data,
                        lastModifiedAt: item.contentModificationDate ?? nil
                    )
                } else if changedFields.contains(.parentItemIdentifier) {
                    guard KDriveVersionConflictResolver.metadataMatches(baseVersion: version.metadataVersion, remoteItem: latestItem) else {
                        throw self.staleVersionError()
                    }
                    let parentID = try self.fileID(forParentIdentifier: item.parentItemIdentifier, runtime: runtime)
                    FileProviderLog.replicatedExtension.debug("move item(\(item.itemIdentifier.rawValue, privacy: .public)) to parentFileID(\(parentID, privacy: .public)) rename(\(changedFields.contains(.filename), privacy: .public))")
                    try await runtime.remote.moveItem(
                        driveID: runtime.configuration.driveID,
                        fileID: fileID,
                        destinationParentID: parentID,
                        name: changedFields.contains(.filename) ? item.filename : nil
                    )
                    updatedItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                } else if changedFields.contains(.filename) {
                    guard KDriveVersionConflictResolver.metadataMatches(baseVersion: version.metadataVersion, remoteItem: latestItem) else {
                        throw self.staleVersionError()
                    }
                    FileProviderLog.replicatedExtension.debug("rename item(\(item.itemIdentifier.rawValue, privacy: .public)) filename(\(item.filename, privacy: .private))")
                    try await runtime.remote.renameItem(
                        driveID: runtime.configuration.driveID,
                        fileID: fileID,
                        name: item.filename
                    )
                    updatedItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                } else {
                    updatedItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                }

                FileProviderLog.replicatedExtension.info("modified item(\(item.itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) remainingFields([])")
                completionHandler(FileProviderItem(remoteItem: updatedItem, rootFileID: runtime.configuration.rootFileID), [], false, nil)
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.replicatedExtension.error("modifyItem(\(item.itemIdentifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(nil, [], false, mappedError)
            }
        }
    }

    public func deleteItem(
        identifier itemIdentifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let optionsDescription = String(describing: options)
        FileProviderLog.replicatedExtension.debug("deleteItem(\(itemIdentifier.rawValue, privacy: .public)) options(\(optionsDescription, privacy: .public)) baseVersion(\(logVersionDescription(version), privacy: .public)) @ domainVersion(\(request.logDomainVersion, privacy: .public))")
        return Progress.cancellable {
            FileProviderLog.replicatedExtension.debug("cancel deleteItem(\(itemIdentifier.rawValue, privacy: .public))")
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.domain)
                let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
                guard let fileID = identifier.fileID(rootFileID: runtime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let latestItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                guard KDriveVersionConflictResolver.itemVersionMatches(
                    contentVersion: version.contentVersion,
                    metadataVersion: version.metadataVersion,
                    remoteItem: latestItem
                ) else {
                    throw self.staleVersionError()
                }
                try await runtime.remote.deleteTrashedItem(driveID: runtime.configuration.driveID, fileID: fileID)
                FileProviderLog.replicatedExtension.info("deleted trashed item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public))")
                completionHandler(nil)
            } catch {
                let mappedError = providerError(error)
                FileProviderLog.replicatedExtension.error("deleteItem(\(itemIdentifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(mappedError)
            }
        }
    }

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        FileProviderLog.replicatedExtension.debug("enumerator(for:\(containerItemIdentifier.rawValue, privacy: .public)) domain(\(self.domain.identifier.rawValue, privacy: .public)) @ domainVersion(\(request.logDomainVersion, privacy: .public))")
        return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, domain: self.domain)
    }

    private func fileID(
        forParentIdentifier parentIdentifier: NSFileProviderItemIdentifier,
        runtime: FileProviderRuntime
    ) throws -> Int {
        if parentIdentifier == .rootContainer {
            return runtime.configuration.rootFileID
        }
        guard parentIdentifier != .trashContainer else {
            throw NSFileProviderError(.cannotSynchronize)
        }
        return try KDriveItemIdentifier(rawValue: parentIdentifier.rawValue).fileID(rootFileID: runtime.configuration.rootFileID)
            ?? runtime.configuration.rootFileID
    }

    private func uploadConflictCopy(
        contents: Data,
        localItem: NSFileProviderItem,
        latestItem: KDriveRemoteItem,
        runtime: FileProviderRuntime
    ) async throws -> KDriveRemoteItem {
        let stagedURL = try stageConflictContents(contents, itemIdentifier: localItem.itemIdentifier)
        let conflictFilename = KDriveConflictFilename.filename(
            for: localItem.filename,
            deviceName: ConflictDeviceName.current
        )
        do {
            let conflictItem = try await runtime.remote.uploadFile(
                driveID: runtime.configuration.driveID,
                parentID: latestItem.parentID,
                fileName: conflictFilename,
                contents: contents,
                lastModifiedAt: localItem.contentModificationDate ?? nil,
                conflictStrategy: .rename
            )
            try? FileManager.default.removeItem(at: stagedURL)
            return conflictItem
        } catch {
            FileProviderLog.replicatedExtension.error("conflict upload failed; staged bytes retained at \(stagedURL.path, privacy: .private): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func stageConflictContents(_ contents: Data, itemIdentifier: NSFileProviderItemIdentifier) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ProviderConstants.appGroupIdentifier) else {
            throw KDriveSnapshotStoreError.missingAppGroupContainer(ProviderConstants.appGroupIdentifier)
        }
        let directoryURL = containerURL.appendingPathComponent("ConflictStaging", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let fileURL = directoryURL
            .appendingPathComponent("\(itemIdentifier.rawValue)-\(UUID().uuidString)")
            .appendingPathExtension("upload")
        try contents.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    private func staleVersionError() -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.cannotSynchronize.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey: "The item changed on the server before the local mutation could be applied.",
                NSLocalizedRecoverySuggestionErrorKey: "Refresh the folder and retry the change."
            ]
        )
    }
}

private enum ConflictDeviceName {
    static var current: String {
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return deviceName.isEmpty ? "This Mac" : deviceName
    }
}

private func logVersionDescription(_ version: NSFileProviderItemVersion?) -> String {
    guard let version else { return "<nil>" }
    return "content:\(version.contentVersion.count)b metadata:\(version.metadataVersion.count)b"
}

private extension NSFileProviderRequest {
    var logDomainVersion: String {
        domainVersion?.description ?? "<nil>"
    }
}

private extension Progress {
    func performTask(_ operation: @escaping @Sendable () async -> Void) -> Progress {
        Task { await operation() }
        return self
    }
}
