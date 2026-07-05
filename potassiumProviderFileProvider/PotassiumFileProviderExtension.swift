import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore
import Darwin
#if canImport(UIKit)
import UIKit
#endif
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
                await ProviderEventRecorder.recordActivity(
                    kind: .fetchContents,
                    runtime: runtime,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: item.name,
                    itemPath: item.path,
                    summary: "Fetched file contents."
                )
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
                await ProviderEventRecorder.recordActivity(
                    kind: .create,
                    runtime: runtime,
                    itemIdentifier: ProviderEventRecorder.itemIdentifier(for: createdItem),
                    itemName: createdItem.name,
                    itemPath: createdItem.path,
                    summary: "Created \(kind)."
                )
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
                        await self.recordBlockedConflict(
                            operation: .trash,
                            itemIdentifier: item.itemIdentifier.rawValue,
                            itemName: item.filename,
                            remoteItem: latestItem,
                            runtime: runtime,
                            summary: "Trash was blocked because the remote item changed first."
                        )
                        throw self.staleVersionError()
                    }
                    FileProviderLog.replicatedExtension.info("trash item(\(item.itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public))")
                    try await runtime.remote.trashItem(driveID: runtime.configuration.driveID, fileID: fileID)
                    await ProviderEventRecorder.recordActivity(
                        kind: .trash,
                        runtime: runtime,
                        itemIdentifier: item.itemIdentifier.rawValue,
                        itemName: latestItem.name,
                        itemPath: latestItem.path,
                        summary: "Moved item to trash."
                    )
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
                        await self.recordBlockedConflict(
                            operation: .modify,
                            itemIdentifier: item.itemIdentifier.rawValue,
                            itemName: item.filename,
                            remoteItem: latestItem,
                            runtime: runtime,
                            summary: "Move was blocked because the remote item changed first."
                        )
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
                        await self.recordBlockedConflict(
                            operation: .modify,
                            itemIdentifier: item.itemIdentifier.rawValue,
                            itemName: item.filename,
                            remoteItem: latestItem,
                            runtime: runtime,
                            summary: "Rename was blocked because the remote item changed first."
                        )
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
                await ProviderEventRecorder.recordActivity(
                    kind: .modify,
                    runtime: runtime,
                    itemIdentifier: ProviderEventRecorder.itemIdentifier(for: updatedItem),
                    itemName: updatedItem.name,
                    itemPath: updatedItem.path,
                    summary: "Modified item."
                )
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
                    await self.recordBlockedConflict(
                        operation: .delete,
                        itemIdentifier: itemIdentifier.rawValue,
                        itemName: latestItem.name,
                        remoteItem: latestItem,
                        runtime: runtime,
                        summary: "Delete was blocked because the remote item changed first."
                    )
                    throw self.staleVersionError()
                }
                try await runtime.remote.deleteTrashedItem(driveID: runtime.configuration.driveID, fileID: fileID)
                FileProviderLog.replicatedExtension.info("deleted trashed item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public))")
                await ProviderEventRecorder.recordActivity(
                    kind: .delete,
                    runtime: runtime,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: latestItem.name,
                    itemPath: latestItem.path,
                    summary: "Deleted trashed item."
                )
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
        var conflictEvent = KDriveConflictEvent(
            domainIdentifier: runtime.configuration.domainIdentifier,
            driveID: runtime.configuration.driveID,
            operation: .modify,
            originalItemIdentifier: localItem.itemIdentifier.rawValue,
            originalItemName: localItem.filename,
            originalItemPath: latestItem.path,
            resolutionState: .unresolved,
            automaticallyResolved: false,
            resolutionKind: nil,
            resolutionSummary: "Detected a stale content edit and started preserving a conflict copy."
        )
        await ProviderEventRecorder.saveConflict(conflictEvent, runtime: runtime)

        do {
            let conflictItem = try await runtime.remote.uploadFile(
                driveID: runtime.configuration.driveID,
                parentID: latestItem.parentID,
                fileName: conflictFilename,
                contents: contents,
                lastModifiedAt: localItem.contentModificationDate ?? nil,
                conflictStrategy: .rename
            )
            conflictEvent.resolvedAt = Date()
            conflictEvent.conflictItemIdentifier = ProviderEventRecorder.itemIdentifier(for: conflictItem)
            conflictEvent.conflictItemName = conflictItem.name
            conflictEvent.conflictItemPath = conflictItem.path
            conflictEvent.resolutionState = .automaticallyResolved
            conflictEvent.automaticallyResolved = true
            conflictEvent.resolutionKind = .preservedBothAsRenamedConflictCopy
            conflictEvent.resolutionSummary = "Uploaded the local edit as a renamed conflict copy and kept the remote item unchanged."
            await ProviderEventRecorder.saveConflict(conflictEvent, runtime: runtime)
            try? FileManager.default.removeItem(at: stagedURL)
            return conflictItem
        } catch {
            conflictEvent.resolvedAt = Date()
            conflictEvent.resolutionState = .failed
            conflictEvent.automaticallyResolved = false
            conflictEvent.resolutionKind = .retainedStagedUploadAfterFailure
            conflictEvent.resolutionSummary = "Could not upload the conflict copy; staged local bytes were retained for inspection."
            conflictEvent.stagedUploadRelativePath = ProviderEventRecorder.relativeStagedPath(for: stagedURL)
            await ProviderEventRecorder.saveConflict(conflictEvent, runtime: runtime)
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

    private func recordBlockedConflict(
        operation: KDriveProviderActivityKind,
        itemIdentifier: String,
        itemName: String?,
        remoteItem: KDriveRemoteItem,
        runtime: FileProviderRuntime,
        summary: String
    ) async {
        let now = Date()
        await ProviderEventRecorder.saveConflict(KDriveConflictEvent(
            detectedAt: now,
            resolvedAt: now,
            domainIdentifier: runtime.configuration.domainIdentifier,
            driveID: runtime.configuration.driveID,
            operation: operation,
            originalItemIdentifier: itemIdentifier,
            originalItemName: itemName ?? remoteItem.name,
            originalItemPath: remoteItem.path,
            resolutionState: .blockedRetryable,
            automaticallyResolved: false,
            resolutionKind: .blockedBeforeServerMutation,
            resolutionSummary: summary
        ), runtime: runtime)
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
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if deviceName.isEmpty == false {
            return deviceName
        }
        #endif
        return hostName ?? "This Mac"
    }

    private static var hostName: String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            gethostname(pointer.baseAddress, pointer.count)
        }
        guard result == 0 else { return nil }

        let hostName = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return hostName.isEmpty ? nil : hostName
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
