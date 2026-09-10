#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore

@MainActor
enum StabilityWarmLaunchObservation {
    static func request(verifyProcess: () throws -> Void,
                        signalWorkingSet: () async throws -> Void) async throws {
        try Task.checkCancellation()
        try verifyProcess()
        try await signalWorkingSet()
        try Task.checkCancellation()
        try verifyProcess()
        // Signal completion is only acknowledgement. The controller still
        // waits for a real, correctly signed provider callback to complete.
    }
}

#endif
