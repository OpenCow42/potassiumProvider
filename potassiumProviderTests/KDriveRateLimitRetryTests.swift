import Foundation
import PotassiumChannelCore
@testable import PotassiumProviderCore
import Testing

@Suite("kDrive rate-limit retry", .serialized)
struct KDriveRateLimitRetryTests {
    @Test func policyPrefersAndCapsRetryAfterSeconds() {
        let decision = KDriveRateLimitRetryPolicy.default.delay(
            retryNumber: 1,
            retryAfter: "120",
            now: Date(timeIntervalSince1970: 0),
            jitterUnitValue: 0
        )

        #expect(decision == KDriveRateLimitRetryDelay(seconds: 60, source: .server))
    }

    @Test func policyParsesStandardAndLegacyHTTPDates() {
        let now = Date(timeIntervalSince1970: 784_111_747)
        let values = [
            "Sun, 06 Nov 1994 08:49:37 GMT",
            "Sunday, 06-Nov-94 08:49:37 GMT",
            "Sun Nov 6 08:49:37 1994",
        ]

        for value in values {
            let decision = KDriveRateLimitRetryPolicy.default.delay(
                retryNumber: 1,
                retryAfter: value,
                now: now,
                jitterUnitValue: 0
            )
            #expect(decision.source == .server)
            #expect(decision.seconds == 30)
        }
    }

    @Test func policyUsesDeterministicBoundedExponentialFallback() {
        let policy = KDriveRateLimitRetryPolicy.default

        #expect(policy.delay(
            retryNumber: 1,
            retryAfter: nil,
            now: .distantPast,
            jitterUnitValue: 0
        ).seconds == 0.8)
        #expect(policy.delay(
            retryNumber: 2,
            retryAfter: "invalid",
            now: .distantPast,
            jitterUnitValue: 0.5
        ).seconds == 2)
        #expect(policy.delay(
            retryNumber: 7,
            retryAfter: nil,
            now: .distantPast,
            jitterUnitValue: 1
        ).seconds == 60)
    }

    @Test func metadataReadHonorsRetryAfterThenSucceeds() async throws {
        let sleeper = RecordingRetrySleeper()
        RateLimitURLProtocol.reset(responses: [
            .init(statusCode: 429, headers: ["Retry-After": "7"], data: Data("limited".utf8)),
            .init(statusCode: 200, data: Self.itemResponseData),
        ])
        let service = makeService(sleeper: sleeper)

        let item = try await service.item(driveID: 100, fileID: 42)

        #expect(item.id == 42)
        #expect(RateLimitURLProtocol.requestCount == 2)
        #expect(sleeper.delays == [7])
    }

    @Test func missingRetryAfterUsesBoundedBackoffAndExhaustsBudget() async {
        let sleeper = RecordingRetrySleeper()
        RateLimitURLProtocol.reset(responses: Array(
            repeating: .init(statusCode: 429, data: Data("limited".utf8)),
            count: 4
        ))
        let service = makeService(sleeper: sleeper)

        do {
            _ = try await service.item(driveID: 100, fileID: 42)
            Issue.record("Expected the retry budget to be exhausted.")
        } catch {
            let rejection = KDriveRemoteErrorClassifier.apiRejection(from: error)
            #expect(rejection?.statusCode == 429)
            #expect(rejection?.recovery == .serverUnreachable)
        }

        #expect(RateLimitURLProtocol.requestCount == 4)
        #expect(sleeper.delays == [1, 2, 4])
    }

    @Test func nonThrottlingFailuresAreNotRetried() async {
        let sleeper = RecordingRetrySleeper()
        RateLimitURLProtocol.reset(responses: [
            .init(statusCode: 503, data: Data("unavailable".utf8)),
            .init(statusCode: 200, data: Self.itemResponseData),
        ])
        let service = makeService(sleeper: sleeper)

        do {
            _ = try await service.item(driveID: 100, fileID: 42)
            Issue.record("Expected a server failure.")
        } catch {
            #expect(KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode == 503)
        }

        #expect(RateLimitURLProtocol.requestCount == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test func mutationRequestsRemainSingleAttempt() async {
        let sleeper = RecordingRetrySleeper()
        RateLimitURLProtocol.reset(responses: [
            .init(statusCode: 429, headers: ["Retry-After": "1"], data: Data("limited".utf8)),
            .init(statusCode: 200, data: Self.itemResponseData),
        ])
        let service = makeService(sleeper: sleeper)

        do {
            _ = try await service.createDirectory(driveID: 100, parentID: 7, name: "Folder")
            Issue.record("Expected the mutation to fail without retry.")
        } catch {
            #expect(KDriveRemoteErrorClassifier.apiRejection(from: error)?.statusCode == 429)
        }

        #expect(RateLimitURLProtocol.requestCount == 1)
        #expect(sleeper.delays.isEmpty)
    }

    @Test func downloadCreatesFreshTransferForRetry() async throws {
        let sleeper = RecordingRetrySleeper()
        let expectedData = Data([0x89, 0x50, 0x4E, 0x47])
        RateLimitURLProtocol.reset(responses: [
            .init(statusCode: 429, headers: ["Retry-After": "2"], data: Data("limited".utf8)),
            .init(statusCode: 200, data: expectedData),
        ])
        let service = makeService(sleeper: sleeper)

        let operation = try service.downloadFileOperation(driveID: 100, fileID: 42)
        let data = try await operation.value

        #expect(data == expectedData)
        #expect(RateLimitURLProtocol.requestCount == 2)
        #expect(sleeper.delays == [2])
    }

    @Test func cancellationDuringBackoffStopsBeforeAnotherRequest() async throws {
        let sleeper = RecordingRetrySleeper(blocks: true)
        RateLimitURLProtocol.reset(responses: [
            .init(statusCode: 429, headers: ["Retry-After": "30"], data: Data("limited".utf8)),
            .init(statusCode: 200, data: Self.itemResponseData),
        ])
        let service = makeService(sleeper: sleeper)
        let task = Task {
            try await service.item(driveID: 100, fileID: 42)
        }

        try await waitUntil { sleeper.delays.count == 1 }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation during backoff.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(RateLimitURLProtocol.requestCount == 1)
    }

    private func makeService(sleeper: RecordingRetrySleeper) -> PotassiumKDriveService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return PotassiumKDriveService(
            bearerToken: "redacted-token",
            apiBaseURL: URL(string: "https://api.example.test")!,
            driveBaseURL: URL(string: "https://drive.example.test")!,
            session: session,
            retryExecutor: KDriveRateLimitRetryExecutor(
                policy: .default,
                sleeper: sleeper,
                clock: FixedRetryClock(date: Date(timeIntervalSince1970: 0)),
                jitter: FixedRetryJitter(value: 0.5)
            )
        )
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while predicate() == false {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for retry state.")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static let itemResponseData = """
    {
      "result": "success",
      "data": {
        "id": 42,
        "name": "Report.txt",
        "path": "/Report.txt",
        "type": "file",
        "status": "active",
        "visibility": "is_private_space",
        "drive_id": 100,
        "parent_id": 7,
        "depth": 1,
        "created_at": 1700000000,
        "last_modified_at": 1700000001,
        "updated_at": 1700000002,
        "size": 4,
        "mime_type": "text/plain",
        "is_favorite": false
      },
      "response_at": 1700000003
    }
    """.data(using: .utf8)!
}

private struct FixedRetryClock: KDriveRetryClock {
    let date: Date

    func now() -> Date {
        date
    }
}

private struct FixedRetryJitter: KDriveRetryJitterProviding {
    let value: Double

    func unitValue() -> Double {
        value
    }
}

private final class RecordingRetrySleeper: KDriveRetrySleeping, @unchecked Sendable {
    private let lock = NSLock()
    private let blocks: Bool
    private var storedDelays: [TimeInterval] = []

    init(blocks: Bool = false) {
        self.blocks = blocks
    }

    var delays: [TimeInterval] {
        lock.withLock { storedDelays }
    }

    func sleep(for seconds: TimeInterval) async throws {
        lock.withLock {
            storedDelays.append(seconds)
        }
        if blocks {
            try await Task.sleep(for: .seconds(30))
        } else {
            try Task.checkCancellation()
        }
    }
}

private final class RateLimitURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        init(statusCode: Int, headers: [String: String] = [:], data: Data) {
            self.statusCode = statusCode
            self.headers = headers
            self.data = data
        }
    }

    private struct State {
        var responses: [Stub] = []
        var requestCount = 0
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var state = State()
    }

    static var requestCount: Int {
        storage.lock.withLock { storage.state.requestCount }
    }

    static func reset(responses: [Stub]) {
        storage.lock.withLock {
            storage.state = State(responses: responses)
        }
    }

    private static let storage = Storage()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let stub = Self.storage.lock.withLock {
            Self.storage.state.requestCount += 1
            guard Self.storage.state.responses.isEmpty == false else {
                return Stub(statusCode: 500, data: Data("missing stub".utf8))
            }
            return Self.storage.state.responses.removeFirst()
        }
        var headers = stub.headers
        headers["Content-Length"] = String(stub.data.count)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
