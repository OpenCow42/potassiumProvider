import Foundation
import PotassiumProviderCore
import Testing

struct StabilityDiagnosticSettlementTests {
    private func event(_ phase: ProviderDiagnosticPhase, span: UUID) -> ProviderDiagnosticEvent {
        ProviderDiagnosticEvent(spanID: span, correlationID: span, source: .fileProviderExtension, operation: .modifyItem, phase: phase)
    }

    @Test func pendingWorkAndNewEventsRestartTheQuietPeriod() {
        var fence = StabilityDiagnosticSettlement()
        let now = ContinuousClock.now, id = UUID(), second = UUID()
        let start = event(.started, span: id), end = event(.completed, span: id)
        func check(_ events: [ProviderDiagnosticEvent], at instant: ContinuousClock.Instant, expecting expected: Bool = false) {
            let settled = fence.observe(events, at: instant)
            #expect(settled == expected)
        }
        check([start], at: now)
        check([start], at: now.advanced(by: .seconds(20)))
        check([start, end], at: now.advanced(by: .seconds(21)))
        check([start, end], at: now.advanced(by: .milliseconds(21_500)))
        let otherStart = event(.started, span: second), otherEnd = event(.completed, span: second)
        check([start, end, otherStart], at: now.advanced(by: .seconds(22)))
        let complete = [start, end, otherStart, otherEnd]
        check(complete, at: now.advanced(by: .seconds(23)))
        check(complete, at: now.advanced(by: .seconds(24)), expecting: true)
    }

    @Test func missingStartsAndContradictoryTerminalsNeverSettle() {
        let id = UUID(), now = ContinuousClock.now
        let start = event(.started, span: id), end = event(.completed, span: id)
        for events in [[end], [start, end, end], [start, start, end]] {
            var fence = StabilityDiagnosticSettlement()
            let initial = fence.observe(events, at: now)
            let later = fence.observe(events, at: now.advanced(by: .seconds(100)))
            #expect(!initial && !later)
        }
    }

    @Test func deliveredMembersDoNotSettleAnOlderCallbackBeforeItsTerminal() {
        let oldStep = UUID(), callback = UUID(), member = UUID(), metadata = UUID(), now = ContinuousClock.now
        let start = ProviderDiagnosticEvent(spanID: callback, correlationID: oldStep,
            source: .fileProviderExtension, operation: .enumerateChanges, phase: .started)
        let delivered = [ProviderDiagnosticPhase.started, .completed].map {
            ProviderDiagnosticEvent(spanID: member, parentSpanID: callback, itemMetadataAlias: $0 == .completed ? metadata : nil,
                correlationID: oldStep, source: .fileProviderExtension, operation: .workingSetRefresh, phase: $0)
        }
        let end = ProviderDiagnosticEvent(spanID: callback, correlationID: oldStep,
            source: .fileProviderExtension, operation: .enumerateChanges, phase: .completed)
        var fence = StabilityDiagnosticSettlement()
        let initiallySettled = fence.observe([start] + delivered, at: now)
        let settledWithoutParent = fence.observe([start] + delivered, at: now.advanced(by: .seconds(30)))
        let settled = [start] + delivered + [end]
        let beforeQuietPeriod = fence.observe(settled, at: now.advanced(by: .seconds(31)))
        let afterQuietPeriod = fence.observe(settled, at: now.advanced(by: .seconds(32)))
        #expect(!initiallySettled && !settledWithoutParent && !beforeQuietPeriod && afterQuietPeriod)
        #expect(settled.allSatisfy { $0.correlationID == oldStep })
    }
}
