import Foundation

struct KDriveRateLimitRetryPolicy: Equatable, Sendable {
    static let `default` = KDriveRateLimitRetryPolicy(
        maximumRetryCount: 3,
        initialBackoff: 1,
        maximumDelay: 60,
        jitterRange: 0.8...1.2
    )

    let maximumRetryCount: Int
    let initialBackoff: TimeInterval
    let maximumDelay: TimeInterval
    let jitterRange: ClosedRange<Double>

    func delay(
        retryNumber: Int,
        retryAfter: String?,
        now: Date,
        jitterUnitValue: Double
    ) -> KDriveRateLimitRetryDelay {
        if let retryAfter,
           let requestedDelay = Self.retryAfterDelay(retryAfter, relativeTo: now) {
            return KDriveRateLimitRetryDelay(
                seconds: min(requestedDelay, maximumDelay),
                source: .server
            )
        }

        let exponent = max(retryNumber - 1, 0)
        let exponentialDelay = initialBackoff * pow(2, Double(exponent))
        let clampedJitter = min(max(jitterUnitValue, 0), 1)
        let jitterMultiplier = jitterRange.lowerBound
            + ((jitterRange.upperBound - jitterRange.lowerBound) * clampedJitter)
        return KDriveRateLimitRetryDelay(
            seconds: min(exponentialDelay * jitterMultiplier, maximumDelay),
            source: .exponential
        )
    }

    private static func retryAfterDelay(
        _ rawValue: String,
        relativeTo now: Date
    ) -> TimeInterval? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Int(value), seconds >= 0 {
            return TimeInterval(seconds)
        }

        for format in httpDateFormats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }

    private static let httpDateFormats = [
        "EEE',' dd MMM yyyy HH':'mm':'ss z",
        "EEEE',' dd-MMM-yy HH':'mm':'ss z",
        "EEE MMM d HH':'mm':'ss yyyy",
    ]
}

struct KDriveRateLimitRetryDelay: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case server
        case exponential
    }

    let seconds: TimeInterval
    let source: Source
}

protocol KDriveRetrySleeping: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

struct TaskKDriveRetrySleeper: KDriveRetrySleeping {
    func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(for: .seconds(seconds))
    }
}

protocol KDriveRetryClock: Sendable {
    func now() -> Date
}

struct SystemKDriveRetryClock: KDriveRetryClock {
    func now() -> Date {
        Date()
    }
}

protocol KDriveRetryJitterProviding: Sendable {
    func unitValue() -> Double
}

struct SystemKDriveRetryJitter: KDriveRetryJitterProviding {
    func unitValue() -> Double {
        Double.random(in: 0...1)
    }
}

struct KDriveRateLimitRetryExecutor: Sendable {
    static let live = KDriveRateLimitRetryExecutor(
        policy: .default,
        sleeper: TaskKDriveRetrySleeper(),
        clock: SystemKDriveRetryClock(),
        jitter: SystemKDriveRetryJitter()
    )

    let policy: KDriveRateLimitRetryPolicy
    let sleeper: any KDriveRetrySleeping
    let clock: any KDriveRetryClock
    let jitter: any KDriveRetryJitterProviding

    func perform<Value>(
        _ work: () async throws -> Value,
        onRetry: (Int, KDriveRateLimitRetryDelay) -> Void
    ) async throws -> Value {
        var retryCount = 0

        while true {
            try Task.checkCancellation()
            do {
                return try await work()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                guard let throttling = KDriveRemoteErrorClassifier.throttling(from: error),
                      retryCount < policy.maximumRetryCount else {
                    throw error
                }

                retryCount += 1
                let delay = policy.delay(
                    retryNumber: retryCount,
                    retryAfter: throttling.retryAfter,
                    now: clock.now(),
                    jitterUnitValue: jitter.unitValue()
                )
                onRetry(retryCount, delay)
                try await sleeper.sleep(for: delay.seconds)
            }
        }
    }
}

struct KDriveRemoteThrottling: Equatable, Sendable {
    let statusCode: Int
    let retryAfter: String?
}
