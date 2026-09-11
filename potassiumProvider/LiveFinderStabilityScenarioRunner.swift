#if os(macOS) && STABILITY
import AppKit
import ApplicationServices
import FileProvider
import Foundation
import PotassiumProviderCore

enum FinderStabilityTargetBinding {
    static func resolve(
        expectedFileID: Int,
        expectedDomainIdentifier: String,
        using resolver: () async throws -> (itemIdentifier: String, domainIdentifier: String)
    ) async throws -> String {
        let actual = try await resolver()
        guard matches(
            expectedFileID: expectedFileID,
            expectedDomainIdentifier: expectedDomainIdentifier,
            actualItemIdentifier: actual.itemIdentifier,
            actualDomainIdentifier: actual.domainIdentifier
        ) else {
            throw FinderLiveError.unsafeTarget
        }
        return actual.itemIdentifier
    }

    static func matches(
        expectedFileID: Int,
        expectedDomainIdentifier: String,
        actualItemIdentifier: String,
        actualDomainIdentifier: String
    ) -> Bool {
        actualItemIdentifier == String(expectedFileID)
            && actualDomainIdentifier == expectedDomainIdentifier
    }
}

@MainActor
enum FinderStabilityScenarioGate {
    static func run<Baseline, Outcome>(
        baseline: () async throws -> Baseline,
        verifySafety: () async throws -> Void,
        execute: () async throws -> Outcome
    ) async throws -> (Baseline, Outcome) {
        let baselineValue = try await baseline()
        try await verifySafety()
        let outcome = try await execute()
        return (baselineValue, outcome)
    }
}
#endif
