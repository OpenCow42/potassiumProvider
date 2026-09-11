#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

@MainActor
struct StabilityLaunchPreparationTests {
    @Test func cachedPreflightActivelyRequestsAnObservationBetweenProcessChecks() async throws {
        var calls: [String] = []
        try await StabilityWarmLaunchObservation.request(
            verifyProcess: { calls.append("verify") },
            signalWorkingSet: { calls.append("signal") })
        #expect(calls == ["verify", "signal", "verify"])
    }

    @Test func changedProcessPreventsSignalOrRejectsItsAcknowledgement() async throws {
        for changeBeforeSignal in [true, false] {
            var changed = changeBeforeSignal, signalCount = 0
            await #expect(throws: StabilityLaunchPreparationError.initialProcessChanged) {
                try await StabilityWarmLaunchObservation.request(
                    verifyProcess: { if changed { throw StabilityLaunchPreparationError.initialProcessChanged } },
                    signalWorkingSet: { signalCount += 1; changed = true })
            }
            #expect(signalCount == (changeBeforeSignal ? 0 : 1))
        }
    }

    @Test func requestFailureCannotAdvancePreparation() async throws {
        var verified = 0
        await #expect(throws: URLError.self) {
            try await StabilityWarmLaunchObservation.request(
                verifyProcess: { verified += 1 },
                signalWorkingSet: { throw URLError(.cannotConnectToHost) })
        }
        #expect(verified == 1)
    }

    @Test func failureEvidenceContainsNoErrorPayloadAndCannotCertifyAcceptance() throws {
        let canary = "private-" + UUID().uuidString
        let error = NSError(domain: canary, code: 17, userInfo: [NSLocalizedDescriptionKey: canary])
        let failure = StabilityLaunchPreparationFailure(stage: .launchPreparation, error: error)
        let data = try JSONEncoder().encode(failure)
        #expect(!String(decoding: data, as: UTF8.self).contains(canary))
        #expect(failure.schemaVersion == 1 && !failure.eligibleForAcceptance)
        #expect(failure.stage == .launchPreparation && failure.reason == "unclassified" && failure.errorCode == 17)
    }
}
#endif
