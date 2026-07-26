#if os(macOS)
import FileProvider
import Foundation
import OSLog
import PotassiumProviderCore

extension PotassiumFileProviderExtension: NSFileProviderKnownFolderSupporting {
    public func getKnownFolderLocations(
        _ knownFolders: NSFileProviderKnownFolders,
        completionHandler: @escaping (NSFileProviderKnownFolderLocations?, Error?) -> Void
    ) {
        let requestsDesktop = knownFolders.contains(.desktop)
        let requestsDocuments = knownFolders.contains(.documents)
        guard requestsDesktop || requestsDocuments else {
            completionHandler(NSFileProviderKnownFolderLocations(), nil)
            return
        }

        Task {
            do {
                let runtime = try await FileProviderRuntime.load(domain: self.fileProviderDomain)
                let privateFileID = try await KDrivePrivateDirectoryResolver.resolveFileID(
                    driveID: runtime.configuration.driveID,
                    rootFileID: runtime.configuration.rootFileID,
                    remote: runtime.remote
                )
                let parentFileID: Int
                let usesActiveLegacyLayout =
                    runtime.configuration.knownFolderLayout == .legacyPrivate
                    && self.fileProviderDomain.replicatedKnownFolders.isEmpty == false
                if usesActiveLegacyLayout {
                    parentFileID = privateFileID
                } else {
                    let namespace = try await KDriveMachineNamespaceResolver.resolveOrCreate(
                        driveID: runtime.configuration.driveID,
                        privateDirectoryFileID: privateFileID,
                        computerName: try KDriveMachineNamespaceName.current(),
                        remote: runtime.remote
                    )
                    parentFileID = namespace.fileID
                    if runtime.configuration.knownFolderLayout == .legacyPrivate {
                        try await FileProviderRuntime.markMachineNamespaceLayout(
                            domain: self.fileProviderDomain
                        )
                    }
                }
                let parentIdentifier = NSFileProviderItemIdentifier(
                    KDriveItemIdentifier.item(parentFileID).rawValue
                )
                let locations = NSFileProviderKnownFolderLocations()
                if requestsDesktop {
                    locations.desktopLocation = NSFileProviderKnownFolderLocations.Location(
                        parentItemIdentifier: parentIdentifier,
                        filename: "Desktop"
                    )
                }
                if requestsDocuments {
                    locations.documentsLocation = NSFileProviderKnownFolderLocations.Location(
                        parentItemIdentifier: parentIdentifier,
                        filename: "Documents"
                    )
                }

                FileProviderLog.replicatedExtension.info("resolved known folders under kDrive parent item(\(parentFileID, privacy: .public)) for domain(\(self.fileProviderDomain.identifier.rawValue, privacy: .public))")
                completionHandler(locations, nil)
            } catch {
                let mappedError: Error
                if error is KDrivePrivateDirectoryResolutionError
                    || error is KDriveMachineNamespaceResolutionError
                    || error is KDriveMachineNamespaceNameError {
                    mappedError = NSFileProviderError(.cannotSynchronize)
                } else {
                    mappedError = providerErrorMapping(error).mappedError
                }
                FileProviderLog.replicatedExtension.error("failed to resolve the kDrive known-folder location for domain(\(self.fileProviderDomain.identifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .private)")
                completionHandler(nil, mappedError)
            }
        }
    }
}
#endif
