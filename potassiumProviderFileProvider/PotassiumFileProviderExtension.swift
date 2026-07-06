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
    private static let maximumConcurrentContentFetches = 4
    private static let contentFetchLimiter = AsyncOperationLimiter(
        maxConcurrentOperations: maximumConcurrentContentFetches
    )

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
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                if identifier == .rootContainer {
                    FileProviderLog.replicatedExtension.debug("resolved root item for domain(\(loadedRuntime.configuration.domainIdentifier, privacy: .public)) driveID(\(loadedRuntime.configuration.driveID, privacy: .public))")
                    completionHandler(FileProviderItem(configuration: loadedRuntime.configuration), nil)
                    return
                }

                let itemIdentifier = try KDriveItemIdentifier(rawValue: identifier.rawValue)
                guard let fileID = itemIdentifier.fileID(rootFileID: loadedRuntime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let item = try await loadedRuntime.remote.item(driveID: loadedRuntime.configuration.driveID, fileID: fileID)
                FileProviderLog.replicatedExtension.debug("resolved item identifier(\(identifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) type(\(item.type ?? "unknown", privacy: .public))")
                completionHandler(FileProviderItem(remoteItem: item, rootFileID: loadedRuntime.configuration.rootFileID), nil)
            } catch {
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: .metadataLookup,
                    itemIdentifier: identifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "resolve item metadata."
                )
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
        let progress = Progress(totalUnitCount: 100)
        let domain = self.domain
        let temporaryDirectoryURL = self.temporaryDirectoryURL

        let task = Task {
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: domain)
                runtime = loadedRuntime
                let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
                guard let fileID = identifier.fileID(rootFileID: loadedRuntime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let fetchedContents = try await Self.contentFetchLimiter.withPermit {
                    try Task.checkCancellation()
                    let data = try await loadedRuntime.remote.downloadFile(
                        driveID: loadedRuntime.configuration.driveID,
                        fileID: fileID
                    )
                    try Task.checkCancellation()
                    let item = try await loadedRuntime.remote.item(
                        driveID: loadedRuntime.configuration.driveID,
                        fileID: fileID
                    )
                    try Task.checkCancellation()
                    let temporaryURL = temporaryDirectoryURL
                        .appendingPathComponent("download-\(UUID().uuidString)")
                        .appendingPathExtension((item.name as NSString).pathExtension)
                    try data.write(to: temporaryURL, options: [.atomic])
                    return FetchedFileContents(
                        temporaryURL: temporaryURL,
                        item: item,
                        byteCount: data.count
                    )
                }

                progress.completedUnitCount = 100
                FileProviderLog.replicatedExtension.info("fetched contents for item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) bytes(\(fetchedContents.byteCount, privacy: .public))")
                await ProviderEventRecorder.recordActivity(
                    kind: .fetchContents,
                    runtime: loadedRuntime,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: fetchedContents.item.name,
                    itemPath: fetchedContents.item.path,
                    summary: "Fetched file contents."
                )
                completionHandler(
                    fetchedContents.temporaryURL,
                    FileProviderItem(remoteItem: fetchedContents.item, rootFileID: loadedRuntime.configuration.rootFileID),
                    nil
                )
            } catch is CancellationError {
                FileProviderLog.replicatedExtension.debug("fetchContents(for:\(itemIdentifier.rawValue, privacy: .public)) cancelled")
                completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            } catch {
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: .fetchContents,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "fetch file contents."
                )
                FileProviderLog.replicatedExtension.error("fetchContents(for:\(itemIdentifier.rawValue, privacy: .public)) failed: \(mappedError.localizedDescription, privacy: .public)")
                completionHandler(nil, nil, mappedError)
            }
        }

        progress.cancellationHandler = {
            FileProviderLog.replicatedExtension.debug("cancel fetchContents(for:\(itemIdentifier.rawValue, privacy: .public))")
            task.cancel()
        }
        return progress
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
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                let coordinator = self.makeMutationCoordinator(runtime: loadedRuntime)
                let parentID = try self.fileID(forParentIdentifier: itemTemplate.parentItemIdentifier, runtime: loadedRuntime)
                let createdItem: KDriveRemoteItem

                if itemTemplate.contentType?.conforms(to: .folder) == true {
                    createdItem = try await coordinator.createDirectory(
                        parentID: parentID,
                        name: itemTemplate.filename
                    )
                } else {
                    let contents = try url.map { try Data(contentsOf: $0) } ?? Data()
                    FileProviderLog.replicatedExtension.debug("upload new file parentFileID(\(parentID, privacy: .public)) bytes(\(contents.count, privacy: .public))")
                    createdItem = try await coordinator.createFile(
                        parentID: parentID,
                        fileName: itemTemplate.filename,
                        contents: contents,
                        lastModifiedAt: itemTemplate.contentModificationDate ?? nil
                    )
                }

                FileProviderLog.replicatedExtension.info("created \(kind, privacy: .public) item(\(createdItem.id, privacy: .public)) parentFileID(\(createdItem.parentID, privacy: .public)) driveID(\(loadedRuntime.configuration.driveID, privacy: .public))")
                await ProviderEventRecorder.recordActivity(
                    kind: .create,
                    runtime: loadedRuntime,
                    itemIdentifier: ProviderEventRecorder.itemIdentifier(for: createdItem),
                    itemName: createdItem.name,
                    itemPath: createdItem.path,
                    summary: "Created \(kind)."
                )
                await self.invalidateCachedSnapshotsAndSignal(
                    runtime: loadedRuntime,
                    containerIdentifiers: self.containerIdentifiers(
                        forFileIDs: [parentID],
                        rootFileID: loadedRuntime.configuration.rootFileID
                    )
                )
                completionHandler(FileProviderItem(remoteItem: createdItem, rootFileID: loadedRuntime.configuration.rootFileID), [], false, nil)
            } catch {
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: .create,
                    itemIdentifier: itemTemplate.parentItemIdentifier.rawValue,
                    itemName: itemTemplate.filename,
                    itemPath: nil,
                    summary: "create \(kind)."
                )
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
            var runtime: FileProviderRuntime?
            let conflictFailureMarker = ConflictFailureMarker()
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                let identifier = try KDriveItemIdentifier(rawValue: item.itemIdentifier.rawValue)
                guard let fileID = identifier.fileID(rootFileID: loadedRuntime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let coordinator = self.makeMutationCoordinator(
                    runtime: loadedRuntime,
                    conflictFailureMarker: conflictFailureMarker
                )
                let baseVersion = KDriveItemBaseVersion(
                    contentVersion: version.contentVersion,
                    metadataVersion: version.metadataVersion
                )
                var affectedContainerIdentifiers: [NSFileProviderItemIdentifier] = []

                if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
                    let latestItem: KDriveRemoteItem
                    do {
                        latestItem = try await coordinator.trashItem(fileID: fileID, baseVersion: baseVersion)
                    } catch let error as KDriveMutationConflictError {
                        await self.recordBlockedConflict(
                            error,
                            operation: .trash,
                            itemIdentifier: item.itemIdentifier.rawValue,
                            itemName: item.filename,
                            runtime: loadedRuntime,
                            summary: "Trash was blocked because the remote item changed first."
                        )
                        throw error
                    }
                    FileProviderLog.replicatedExtension.info("trash item(\(item.itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public))")
                    affectedContainerIdentifiers.append(contentsOf: self.containerIdentifiers(
                        forFileIDs: [
                            KDriveItemMetadataVersion(data: version.metadataVersion)?.parentID,
                            latestItem.parentID
                        ],
                        rootFileID: loadedRuntime.configuration.rootFileID
                    ))
                    affectedContainerIdentifiers.append(.trashContainer)
                    await ProviderEventRecorder.recordActivity(
                        kind: .trash,
                        runtime: loadedRuntime,
                        itemIdentifier: item.itemIdentifier.rawValue,
                        itemName: latestItem.name,
                        itemPath: latestItem.path,
                        summary: "Moved item to trash."
                    )
                    await self.invalidateCachedSnapshotsAndSignal(
                        runtime: loadedRuntime,
                        containerIdentifiers: affectedContainerIdentifiers
                    )
                    completionHandler(nil, [], false, nil)
                    return
                }

                let updatedItem: KDriveRemoteItem
                var replacedContents = false
                if let newContents, changedFields.contains(.contents) {
                    let data = try Data(contentsOf: newContents)
                    FileProviderLog.replicatedExtension.debug("replace contents for item(\(item.itemIdentifier.rawValue, privacy: .public)) bytes(\(data.count, privacy: .public))")
                    let result = try await coordinator.replaceContents(
                        itemIdentifier: item.itemIdentifier.rawValue,
                        fileID: fileID,
                        localFilename: item.filename,
                        baseContentVersion: version.contentVersion,
                        contents: data,
                        lastModifiedAt: item.contentModificationDate ?? nil
                    )
                    switch result {
                    case .replaced(let replacedItem):
                        updatedItem = replacedItem
                        replacedContents = true
                    case .conflictCopy(let conflictItem):
                        FileProviderLog.replicatedExtension.info("preserved stale content edit as conflict item(\(conflictItem.id, privacy: .public)) original(\(fileID, privacy: .public))")
                        await self.invalidateCachedSnapshotsAndSignal(
                            runtime: loadedRuntime,
                            containerIdentifiers: self.containerIdentifiers(
                                forFileIDs: [conflictItem.parentID],
                                rootFileID: loadedRuntime.configuration.rootFileID
                            )
                        )
                        completionHandler(FileProviderItem(remoteItem: conflictItem, rootFileID: loadedRuntime.configuration.rootFileID), [], false, nil)
                        return
                    }
                    affectedContainerIdentifiers.append(contentsOf: self.containerIdentifiers(
                        forFileIDs: [updatedItem.parentID],
                        rootFileID: loadedRuntime.configuration.rootFileID
                    ))
                } else if changedFields.contains(.parentItemIdentifier) {
                    do {
                        let parentID = try self.fileID(forParentIdentifier: item.parentItemIdentifier, runtime: loadedRuntime)
                        FileProviderLog.replicatedExtension.debug("move item(\(item.itemIdentifier.rawValue, privacy: .public)) to parentFileID(\(parentID, privacy: .public)) rename(\(changedFields.contains(.filename), privacy: .public))")
                        updatedItem = try await coordinator.moveItem(
                            fileID: fileID,
                            baseMetadataVersion: version.metadataVersion,
                            destinationParentID: parentID,
                            name: changedFields.contains(.filename) ? item.filename : nil
                        )
                        affectedContainerIdentifiers.append(contentsOf: self.containerIdentifiers(
                            forFileIDs: [
                                KDriveItemMetadataVersion(data: version.metadataVersion)?.parentID,
                                parentID,
                                updatedItem.parentID
                            ],
                            rootFileID: loadedRuntime.configuration.rootFileID
                        ))
                    } catch let error as KDriveMutationConflictError {
                        await self.recordBlockedConflict(
                            error,
                            operation: .modify,
                            itemIdentifier: item.itemIdentifier.rawValue,
                            itemName: item.filename,
                            runtime: loadedRuntime,
                            summary: "Move was blocked because the remote item changed first."
                        )
                        throw error
                    }
                } else if changedFields.contains(.filename) {
                    do {
                        FileProviderLog.replicatedExtension.debug("rename item(\(item.itemIdentifier.rawValue, privacy: .public)) filename(\(item.filename, privacy: .private))")
                        updatedItem = try await coordinator.renameItem(
                            fileID: fileID,
                            baseMetadataVersion: version.metadataVersion,
                            name: item.filename
                        )
                        affectedContainerIdentifiers.append(contentsOf: self.containerIdentifiers(
                            forFileIDs: [
                                KDriveItemMetadataVersion(data: version.metadataVersion)?.parentID,
                                updatedItem.parentID
                            ],
                            rootFileID: loadedRuntime.configuration.rootFileID
                        ))
                    } catch let error as KDriveMutationConflictError {
                        await self.recordBlockedConflict(
                            error,
                            operation: .modify,
                            itemIdentifier: item.itemIdentifier.rawValue,
                            itemName: item.filename,
                            runtime: loadedRuntime,
                            summary: "Rename was blocked because the remote item changed first."
                        )
                        throw error
                    }
                } else {
                    updatedItem = try await loadedRuntime.remote.item(driveID: loadedRuntime.configuration.driveID, fileID: fileID)
                }

                FileProviderLog.replicatedExtension.info("modified item(\(item.itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public)) remainingFields([])")
                if replacedContents {
                    await ThumbnailCacheInvalidation.removeCachedThumbnail(for: updatedItem, runtime: loadedRuntime)
                }
                await ProviderEventRecorder.recordActivity(
                    kind: .modify,
                    runtime: loadedRuntime,
                    itemIdentifier: ProviderEventRecorder.itemIdentifier(for: updatedItem),
                    itemName: updatedItem.name,
                    itemPath: updatedItem.path,
                    summary: "Modified item."
                )
                if updatedItem.isDirectory {
                    affectedContainerIdentifiers.append(NSFileProviderItemIdentifier(
                        KDriveItemIdentifier.item(updatedItem.id).rawValue
                    ))
                }
                await self.invalidateCachedSnapshotsAndSignal(
                    runtime: loadedRuntime,
                    containerIdentifiers: affectedContainerIdentifiers
                )
                completionHandler(FileProviderItem(remoteItem: updatedItem, rootFileID: loadedRuntime.configuration.rootFileID), [], false, nil)
            } catch {
                let conflictFailureAlreadyRecorded = await conflictFailureMarker.didRecordFailure()
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: .modify,
                    itemIdentifier: item.itemIdentifier.rawValue,
                    itemName: item.filename,
                    itemPath: nil,
                    summary: "modify item.",
                    shouldRecord: conflictFailureAlreadyRecorded == false
                )
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
            var runtime: FileProviderRuntime?
            do {
                let loadedRuntime = try await FileProviderRuntime.load(domain: self.domain)
                runtime = loadedRuntime
                let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
                guard let fileID = identifier.fileID(rootFileID: loadedRuntime.configuration.rootFileID) else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let coordinator = self.makeMutationCoordinator(runtime: loadedRuntime)
                let baseVersion = KDriveItemBaseVersion(
                    contentVersion: version.contentVersion,
                    metadataVersion: version.metadataVersion
                )
                let latestItem: KDriveRemoteItem
                do {
                    latestItem = try await coordinator.deleteTrashedItem(fileID: fileID, baseVersion: baseVersion)
                } catch let error as KDriveMutationConflictError {
                    await self.recordBlockedConflict(
                        error,
                        operation: .delete,
                        itemIdentifier: itemIdentifier.rawValue,
                        itemName: nil,
                        runtime: loadedRuntime,
                        summary: "Delete was blocked because the remote item changed first."
                    )
                    throw error
                }
                FileProviderLog.replicatedExtension.info("deleted trashed item(\(itemIdentifier.rawValue, privacy: .public)) kDriveFileID(\(fileID, privacy: .public))")
                await ThumbnailCacheInvalidation.removeCachedThumbnail(for: latestItem, runtime: loadedRuntime)
                await ProviderEventRecorder.recordActivity(
                    kind: .delete,
                    runtime: loadedRuntime,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: latestItem.name,
                    itemPath: latestItem.path,
                    summary: "Deleted trashed item."
                )
                await self.invalidateCachedSnapshotsAndSignal(
                    runtime: loadedRuntime,
                    containerIdentifiers: [.trashContainer]
                )
                completionHandler(nil)
            } catch {
                let mappedError = await self.recordProviderFailure(
                    error,
                    runtime: runtime,
                    fallbackKind: .delete,
                    itemIdentifier: itemIdentifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "delete item."
                )
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

    func recordProviderFailure(
        _ error: Error,
        runtime: FileProviderRuntime?,
        fallbackKind: KDriveProviderActivityKind,
        itemIdentifier: String?,
        itemName: String?,
        itemPath: String?,
        summary: String,
        shouldRecord: Bool = true
    ) async -> Error {
        let mapping = providerErrorMapping(error)
        guard shouldRecord, shouldRecordGenericFailure(for: error) else {
            return mapping.mappedError
        }

        if let runtime {
            await ProviderEventRecorder.recordFailure(
                kind: fallbackKind,
                runtime: runtime,
                itemIdentifier: itemIdentifier,
                itemName: itemName,
                itemPath: itemPath,
                summary: summary,
                diagnostic: mapping.diagnostic
            )
        } else {
            await ProviderEventRecorder.recordFailure(
                kind: providerActivityKindForRuntimeLoadFailure(error),
                eventStore: FileProviderRuntime.makeEventStore(),
                domainIdentifier: domain.identifier.rawValue,
                itemIdentifier: itemIdentifier,
                itemName: itemName,
                itemPath: itemPath,
                summary: "Could not load File Provider runtime for \(summary.lowercased())",
                diagnostic: mapping.diagnostic
            )
        }

        return mapping.mappedError
    }

    private func makeMutationCoordinator(
        runtime: FileProviderRuntime,
        conflictFailureMarker: ConflictFailureMarker? = nil
    ) -> KDriveMutationCoordinator {
        KDriveMutationCoordinator(
            configuration: runtime.configuration,
            remote: runtime.remote,
            conflictDeviceName: { ConflictDeviceName.current },
            contentConflictObserver: { event in
                if case .failed = event {
                    await conflictFailureMarker?.markFailed()
                }
                await Self.recordContentConflictEvent(event, runtime: runtime)
            }
        )
    }

    private func containerIdentifiers(forFileIDs fileIDs: [Int?], rootFileID: Int) -> [NSFileProviderItemIdentifier] {
        fileIDs.compactMap { fileID in
            fileID.map { self.containerIdentifier(forFileID: $0, rootFileID: rootFileID) }
        }
    }

    private func containerIdentifier(forFileID fileID: Int, rootFileID: Int) -> NSFileProviderItemIdentifier {
        if fileID == rootFileID {
            return .rootContainer
        }
        return NSFileProviderItemIdentifier(KDriveItemIdentifier.item(fileID).rawValue)
    }

    private func invalidateCachedSnapshotsAndSignal(
        runtime: FileProviderRuntime,
        containerIdentifiers: [NSFileProviderItemIdentifier]
    ) async {
        let uniqueIdentifiers = uniqueContainerIdentifiers(containerIdentifiers)
        guard uniqueIdentifiers.isEmpty == false else { return }

        for containerIdentifier in uniqueIdentifiers {
            let snapshotContainerIdentifier = Self.snapshotContainerIdentifier(for: containerIdentifier)
            do {
                try await runtime.snapshotStore.removeSnapshot(
                    domainIdentifier: runtime.configuration.domainIdentifier,
                    containerIdentifier: snapshotContainerIdentifier
                )
            } catch {
                let mapping = providerErrorMapping(error)
                FileProviderLog.replicatedExtension.error("failed to invalidate snapshot container(\(snapshotContainerIdentifier, privacy: .public)): \(mapping.mappedError.localizedDescription, privacy: .public)")
                await ProviderEventRecorder.recordFailure(
                    kind: .changeSync,
                    runtime: runtime,
                    itemIdentifier: containerIdentifier.rawValue,
                    itemName: nil,
                    itemPath: nil,
                    summary: "Could not invalidate cached folder state.",
                    diagnostic: mapping.diagnostic
                )
            }

            await signalEnumerator(for: containerIdentifier, runtime: runtime)
        }
    }

    private func signalEnumerator(
        for containerIdentifier: NSFileProviderItemIdentifier,
        runtime: FileProviderRuntime
    ) async {
        await withCheckedContinuation { continuation in
            manager.signalEnumerator(for: containerIdentifier) { error in
                if let error {
                    let mapping = providerErrorMapping(error)
                    FileProviderLog.replicatedExtension.error("failed to signal enumerator container(\(containerIdentifier.rawValue, privacy: .public)): \(mapping.mappedError.localizedDescription, privacy: .public)")
                    Task {
                        await ProviderEventRecorder.recordFailure(
                            kind: .changeSync,
                            runtime: runtime,
                            itemIdentifier: containerIdentifier.rawValue,
                            itemName: nil,
                            itemPath: nil,
                            summary: "Could not signal File Provider to refresh a folder.",
                            diagnostic: mapping.diagnostic
                        )
                    }
                }
                continuation.resume()
            }
        }
    }

    private func uniqueContainerIdentifiers(_ identifiers: [NSFileProviderItemIdentifier]) -> [NSFileProviderItemIdentifier] {
        var seenRawValues = Set<String>()
        var uniqueIdentifiers: [NSFileProviderItemIdentifier] = []
        for identifier in identifiers where seenRawValues.insert(identifier.rawValue).inserted {
            uniqueIdentifiers.append(identifier)
        }
        return uniqueIdentifiers
    }

    private static func snapshotContainerIdentifier(for containerIdentifier: NSFileProviderItemIdentifier) -> String {
        switch containerIdentifier {
        case .workingSet:
            return "working-set"
        case .rootContainer:
            return "root"
        case .trashContainer:
            return "trash"
        default:
            return containerIdentifier.rawValue
        }
    }

    private static func recordContentConflictEvent(
        _ event: KDriveStaleContentConflictEvent,
        runtime: FileProviderRuntime
    ) async {
        switch event {
        case .started(let context):
            await ProviderEventRecorder.saveConflict(KDriveConflictEvent(
                id: context.id,
                detectedAt: context.detectedAt,
                domainIdentifier: runtime.configuration.domainIdentifier,
                driveID: runtime.configuration.driveID,
                operation: .modify,
                originalItemIdentifier: context.localItemIdentifier,
                originalItemName: context.localFilename,
                originalItemPath: context.latestItem.path,
                resolutionState: .unresolved,
                automaticallyResolved: false,
                resolutionKind: nil,
                resolutionSummary: "Detected a stale content edit and started preserving a conflict copy."
            ), runtime: runtime)

        case .resolved(let context, let conflictItem, let resolvedAt):
            await ProviderEventRecorder.saveConflict(KDriveConflictEvent(
                id: context.id,
                detectedAt: context.detectedAt,
                resolvedAt: resolvedAt,
                domainIdentifier: runtime.configuration.domainIdentifier,
                driveID: runtime.configuration.driveID,
                operation: .modify,
                originalItemIdentifier: context.localItemIdentifier,
                originalItemName: context.localFilename,
                originalItemPath: context.latestItem.path,
                conflictItemIdentifier: ProviderEventRecorder.itemIdentifier(for: conflictItem),
                conflictItemName: conflictItem.name,
                conflictItemPath: conflictItem.path,
                resolutionState: .automaticallyResolved,
                automaticallyResolved: true,
                resolutionKind: .preservedBothAsRenamedConflictCopy,
                resolutionSummary: "Uploaded the local edit as a renamed conflict copy and kept the remote item unchanged."
            ), runtime: runtime)

        case .failed(let context, let failedAt):
            await ProviderEventRecorder.saveConflict(KDriveConflictEvent(
                id: context.id,
                detectedAt: context.detectedAt,
                resolvedAt: failedAt,
                domainIdentifier: runtime.configuration.domainIdentifier,
                driveID: runtime.configuration.driveID,
                operation: .modify,
                originalItemIdentifier: context.localItemIdentifier,
                originalItemName: context.localFilename,
                originalItemPath: context.latestItem.path,
                resolutionState: .failed,
                automaticallyResolved: false,
                resolutionKind: .retainedStagedUploadAfterFailure,
                resolutionSummary: "Could not upload the conflict copy; staged local bytes were retained for inspection.",
                stagedUploadRelativePath: ProviderEventRecorder.relativeStagedPath(for: context.stagedURL)
            ), runtime: runtime)
            FileProviderLog.replicatedExtension.error("conflict upload failed; staged bytes retained at \(context.stagedURL.path, privacy: .private)")
        }
    }

    private func recordBlockedConflict(
        _ error: KDriveMutationConflictError,
        operation: KDriveProviderActivityKind,
        itemIdentifier: String,
        itemName: String?,
        runtime: FileProviderRuntime,
        summary: String
    ) async {
        switch error {
        case .staleVersion(let latestItem):
            await recordBlockedConflict(
                operation: operation,
                itemIdentifier: itemIdentifier,
                itemName: itemName,
                remoteItem: latestItem,
                runtime: runtime,
                summary: summary
            )
        }
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

}

private actor ConflictFailureMarker {
    private var didFail = false

    func markFailed() {
        didFail = true
    }

    func didRecordFailure() -> Bool {
        didFail
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

private struct FetchedFileContents: Sendable {
    let temporaryURL: URL
    let item: KDriveRemoteItem
    let byteCount: Int
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
