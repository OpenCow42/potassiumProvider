#if os(macOS) && STABILITY
import PotassiumProviderCore

/// Selection happens before beginning a step, binding a target, or invoking UI.
/// Deferral never changes the failure state of the subsequent scenarios.
struct FinderStabilityScenarioSelection {
    var conflictCase: StabilityLiveConflictCase? = nil
    var includePermanentDeletion = false

    func skipReason(for scenario: StabilityFinderScenario, afterFailure: Bool) -> StabilityFinderStepSkipReason? {
        if let conflictCase, scenario != conflictCase.scenario { return .notSelectedForConflictProfile }
        // These cases prepare their own fixture and repeat the normal safety preflight.
        // Keep the earlier failed result; independence does not turn it into a pass.
        let independent = conflictCase == nil && [.concurrentRemotePreserveBoth, .cancellationAndProgress, .workingSetRefresh, .supportedContextualActions].contains(scenario)
        if afterFailure && !independent { return .earlierStepFailure }
        if conflictCase == nil, scenario == .permanentDeletion, !includePermanentDeletion {
            return .permanentDeletionNotSelected
        }
        return nil
    }
}
#endif
