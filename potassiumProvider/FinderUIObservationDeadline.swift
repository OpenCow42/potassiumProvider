#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore

/// Ordinary UI observations remain bounded even inside a long transfer scenario.
enum FinderUIObservationDeadline {
    static func make(remaining: Duration, now: ContinuousClock.Instant = .now) -> StabilityDeadline {
        StabilityDeadline(budget: min(max(.zero, remaining), .seconds(90)), now: now)
    }
}
#endif
