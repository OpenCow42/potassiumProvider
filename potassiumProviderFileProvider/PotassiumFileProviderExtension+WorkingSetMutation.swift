import Foundation
import PotassiumProviderCore

extension PotassiumFileProviderExtension {
    /// The remote mutation is already committed. Journal failure is diagnostic;
    /// it must not turn this callback into a second remote mutation on retry.
    func publishKnownWorkingSetItem(_ item: KDriveRemoteItem, replacing expected: KDriveRemoteItem?,
                                   runtime: FileProviderRuntime) async {
        // The configured root has a synthetic File Provider identity. Never
        // publish it as a normal child under its server-side external parent.
        guard item.id != runtime.configuration.rootFileID,
              item.driveID == runtime.configuration.driveID else { return }
        do {
            _ = try await runtime.workingSetStateStore.publishKnownWorkingSetItem(item, replacing: expected,
                domainIdentifier: runtime.configuration.domainIdentifier, recordedAt: Date())
        } catch {
            let mapping = providerErrorMapping(error)
            await ProviderEventRecorder.recordFailure(kind: .changeSync, runtime: runtime,
                itemIdentifier: String(item.id), itemName: nil, itemPath: nil,
                summary: "Could not journal the confirmed mutation for working-set delivery.", diagnostic: mapping.diagnostic)
        }
    }
}
