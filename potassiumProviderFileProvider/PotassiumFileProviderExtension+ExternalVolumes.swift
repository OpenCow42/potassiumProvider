#if os(macOS)
import FileProvider
import OSLog

@available(macOS 15.0, *)
extension PotassiumFileProviderExtension: NSFileProviderExternalVolumeHandling {
    public func shouldConnectExternalDomain(
        completionHandler: @escaping (Error?) -> Void
    ) {
        let domain = fileProviderDomain
        Task { [weak self] in
            do {
                try await FileProviderRuntime.approveExternalDomainConnection(domain: domain)
                guard let self else {
                    completionHandler(NSFileProviderError(.notAuthenticated))
                    return
                }
                self.startRemotePolling()
                FileProviderLog.replicatedExtension.info("approved external domain connection for domain(\(domain.identifier.rawValue, privacy: .public))")
                completionHandler(nil)
            } catch {
                self?.stopRemotePolling()
                FileProviderLog.replicatedExtension.error("rejected external domain connection for domain(\(domain.identifier.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                completionHandler(NSFileProviderError(.notAuthenticated))
            }
        }
    }
}
#endif
