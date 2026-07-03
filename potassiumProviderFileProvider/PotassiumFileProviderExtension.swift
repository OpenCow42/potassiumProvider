import FileProvider
import Foundation
import PotassiumProviderCore
import UniformTypeIdentifiers

public final class PotassiumFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain
    private let manager: NSFileProviderManager
    private let temporaryDirectoryURL: URL

    public required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.manager = NSFileProviderManager(for: domain)!
        self.temporaryDirectoryURL = (try? manager.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
        super.init()
    }

    public func invalidate() {}

    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        Progress.cancellable {
            completionHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try FileProviderRuntime(domain: self.domain)
                if identifier == .rootContainer {
                    completionHandler(FileProviderItem(configuration: runtime.configuration), nil)
                    return
                }

                let itemIdentifier = try KDriveItemIdentifier(rawValue: identifier.rawValue)
                guard let fileID = itemIdentifier.fileID else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let item = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                completionHandler(FileProviderItem(remoteItem: item), nil)
            } catch {
                completionHandler(nil, providerError(error))
            }
        }
    }

    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        Progress.cancellable {
            completionHandler(nil, nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try FileProviderRuntime(domain: self.domain)
                let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
                guard let fileID = identifier.fileID else {
                    throw NSFileProviderError(.noSuchItem)
                }

                let data = try await runtime.remote.downloadFile(driveID: runtime.configuration.driveID, fileID: fileID)
                let item = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                let temporaryURL = self.temporaryDirectoryURL
                    .appendingPathComponent("download-\(UUID().uuidString)")
                    .appendingPathExtension((item.name as NSString).pathExtension)
                try data.write(to: temporaryURL, options: [.atomic])
                completionHandler(temporaryURL, FileProviderItem(remoteItem: item), nil)
            } catch {
                completionHandler(nil, nil, providerError(error))
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
        Progress.cancellable {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try FileProviderRuntime(domain: self.domain)
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
                    createdItem = try await runtime.remote.uploadFile(
                        driveID: runtime.configuration.driveID,
                        parentID: parentID,
                        fileName: itemTemplate.filename,
                        contents: contents,
                        lastModifiedAt: itemTemplate.contentModificationDate ?? nil
                    )
                }

                completionHandler(FileProviderItem(remoteItem: createdItem), [], false, nil)
            } catch {
                completionHandler(nil, [], false, providerError(error))
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
        Progress.cancellable {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try FileProviderRuntime(domain: self.domain)
                let identifier = try KDriveItemIdentifier(rawValue: item.itemIdentifier.rawValue)
                guard let fileID = identifier.fileID else {
                    throw NSFileProviderError(.noSuchItem)
                }

                if changedFields.contains(.parentItemIdentifier), item.parentItemIdentifier == .trashContainer {
                    try await runtime.remote.trashItem(driveID: runtime.configuration.driveID, fileID: fileID)
                    completionHandler(nil, [], false, nil)
                    return
                }

                let updatedItem: KDriveRemoteItem
                if let newContents, changedFields.contains(.contents) {
                    let data = try Data(contentsOf: newContents)
                    updatedItem = try await runtime.remote.replaceFile(
                        driveID: runtime.configuration.driveID,
                        fileID: fileID,
                        contents: data,
                        lastModifiedAt: item.contentModificationDate ?? nil
                    )
                } else if changedFields.contains(.parentItemIdentifier) {
                    let parentID = try self.fileID(forParentIdentifier: item.parentItemIdentifier, runtime: runtime)
                    try await runtime.remote.moveItem(
                        driveID: runtime.configuration.driveID,
                        fileID: fileID,
                        destinationParentID: parentID,
                        name: changedFields.contains(.filename) ? item.filename : nil
                    )
                    updatedItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                } else if changedFields.contains(.filename) {
                    try await runtime.remote.renameItem(
                        driveID: runtime.configuration.driveID,
                        fileID: fileID,
                        name: item.filename
                    )
                    updatedItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                } else {
                    updatedItem = try await runtime.remote.item(driveID: runtime.configuration.driveID, fileID: fileID)
                }

                completionHandler(FileProviderItem(remoteItem: updatedItem), [], false, nil)
            } catch {
                completionHandler(nil, [], false, providerError(error))
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
        Progress.cancellable {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }.performTask {
            do {
                let runtime = try FileProviderRuntime(domain: self.domain)
                let identifier = try KDriveItemIdentifier(rawValue: itemIdentifier.rawValue)
                guard let fileID = identifier.fileID else {
                    throw NSFileProviderError(.noSuchItem)
                }

                try await runtime.remote.deleteTrashedItem(driveID: runtime.configuration.driveID, fileID: fileID)
                completionHandler(nil)
            } catch {
                completionHandler(providerError(error))
            }
        }
    }

    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        let runtime = try FileProviderRuntime(domain: domain)
        return FileProviderEnumerator(containerItemIdentifier: containerItemIdentifier, runtime: runtime)
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
        return try KDriveItemIdentifier(rawValue: parentIdentifier.rawValue).fileID
            ?? runtime.configuration.rootFileID
    }
}

private extension Progress {
    func performTask(_ operation: @escaping @Sendable () async -> Void) -> Progress {
        Task { await operation() }
        return self
    }
}
