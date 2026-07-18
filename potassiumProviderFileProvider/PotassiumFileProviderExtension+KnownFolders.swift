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
                let parentIdentifier = NSFileProviderItemIdentifier(
                    KDriveItemIdentifier.item(privateFileID).rawValue
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

                FileProviderLog.replicatedExtension.info("resolved known folders under kDrive Private item(\(privateFileID, privacy: .public)) for domain(\(self.fileProviderDomain.identifier.rawValue, privacy: .public))")
                completionHandler(locations, nil)
            } catch {
                let mappedError: Error
                if error is KDrivePrivateDirectoryResolutionError {
                    mappedError = NSFileProviderError(.cannotSynchronize)
                } else {
                    mappedError = providerErrorMapping(error).mappedError
                }
                FileProviderLog.replicatedExtension.error("failed to resolve kDrive Private location for known folders in domain(\(self.fileProviderDomain.identifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                completionHandler(nil, mappedError)
            }
        }
    }
}
#endif
