import Foundation

/// A local recorder fence, independent of server polling and Retry-After.
/// Every span must close exactly once and the stream must then remain quiet.
public struct StabilityDiagnosticSettlement: Sendable {
    private let quietPeriod: Duration
    private var eventCount: Int?
    private var lastEventID: UUID?
    private var quietSince: ContinuousClock.Instant?

    public init(quietPeriod: Duration = .seconds(1)) {
        self.quietPeriod = quietPeriod
    }

    public mutating func observe(_ events: [ProviderDiagnosticEvent], at now: ContinuousClock.Instant = .now) -> Bool {
        if eventCount != events.count || lastEventID != events.last?.id {
            eventCount = events.count
            lastEventID = events.last?.id
            quietSince = nil
        }
        let spans = Dictionary(grouping: events.filter { $0.spanID != nil }, by: { $0.spanID! })
        guard spans.values.allSatisfy({ span in
            span.filter { $0.phase == .started }.count == 1 &&
                span.filter { [.completed, .failed, .cancelled].contains($0.phase) }.count == 1
        }) else {
            quietSince = nil
            return false
        }
        guard let quietSince else { self.quietSince = now; return false }
        return quietSince.duration(to: now) >= quietPeriod
    }
}
