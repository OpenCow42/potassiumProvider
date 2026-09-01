import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing

@Suite("Version-pinned kDrive API evidence", .serialized)
struct KDriveAPIEvidenceTests {
    @Test("Share-link access supports inherit")
    func shareLinkAccessSupportsInherit() async throws {
        #expect(KDriveShareLinkConfiguration.Access.allCases.contains(.inherit))

        let (service, session) = await makeService(returningShareLinkRight: "inherit")
        defer { session.invalidateAndCancel() }
        let summary = try #require(try await service.shareLink(driveID: 11, fileID: 22))

        #expect(summary.configuration.access == .inherit)
    }

    @Test("Unknown share-link access fails closed")
    func unknownShareLinkAccessFailsClosed() async throws {
        let (service, session) = await makeService(returningShareLinkRight: "unrecognized")
        defer { session.invalidateAndCancel() }

        await #expect(throws: KDriveContextActionError.unsupportedShareLinkAccess) {
            _ = try await service.shareLink(driveID: 11, fileID: 22)
        }
    }

    @Test("Share-link update explicitly clears expiration and preserves inherit access")
    func shareLinkUpdateEncodesExplicitNullExpiration() async throws {
        await KDriveAPIEvidenceURLProtocol.reset(returningShareLinkRight: "inherit")
        let session = evidenceSession()
        defer { session.invalidateAndCancel() }
        let service = PotassiumKDriveService(
            bearerToken: "",
            apiBaseURL: evidenceBaseURL,
            session: session
        )
        let configuration = KDriveShareLinkConfiguration(
            access: .inherit,
            validUntil: nil,
            allowsDownload: false
        )

        let summary = try await service.updateShareLink(
            driveID: 11,
            fileID: 22,
            configuration: configuration
        )

        #expect(summary.configuration.access == .inherit)
        let requests = await KDriveAPIEvidenceURLProtocol.recordedRequests()
        let update = try #require(requests.first { $0.request.httpMethod == "PUT" })
        let requestURL = try #require(update.request.url)
        #expect(requestURL.path == "/2/drive/11/files/22/link")
        let body = try #require(update.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["right"] as? String == "inherit")
        #expect(json["valid_until"] is NSNull)
        #expect(json["can_download"] as? Bool == false)
    }

    @Test("Duplicate request carries an explicit caller-selected name")
    func duplicateRequestEncodesExplicitName() async throws {
        await KDriveAPIEvidenceURLProtocol.reset(returningShareLinkRight: "inherit")
        let session = evidenceSession()
        defer { session.invalidateAndCancel() }
        let service = PotassiumKDriveService(
            bearerToken: "",
            apiBaseURL: evidenceBaseURL,
            session: session
        )

        let duplicate = try await service.duplicateItem(
            driveID: 11,
            fileID: 22,
            name: "Evidence copy.txt"
        )

        #expect(duplicate.name == "Evidence copy.txt")
        let captured = try #require(
            await KDriveAPIEvidenceURLProtocol.recordedRequests().first
        )
        let requestURL = try #require(captured.request.url)
        #expect(captured.request.httpMethod == "POST")
        #expect(requestURL.path == "/3/drive/11/files/22/duplicate")
        let body = try #require(captured.body)
        let json = try #require(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["name"] as? String == "Evidence copy.txt")
        #expect(json.isEmpty == false)
    }

    @Test("Direct upload byte-count validation enforces the documented boundary")
    func directUploadByteCountBoundary() throws {
        let maximum = PotassiumKDriveService.directUploadMaximumByteCount

        #expect(maximum == 1_000_000_000)
        #expect(
            KDriveDirectUploadError.requiresUploadSession(maximumByteCount: maximum).recovery
                == .cannotSynchronize
        )
        #expect(
            KDriveDirectUploadError.requiresUploadSession(maximumByteCount: maximum)
                .diagnosticCategory == .validation
        )
        #expect(
            KDriveDirectUploadError.requiresUploadSession(maximumByteCount: maximum)
                .diagnosticSummary
                == "The direct-upload size limit requires a session-backed transfer."
        )
        #expect(
            KDriveDirectUploadError.requiresUploadSession(maximumByteCount: maximum)
                .recoverySuggestion
                == "Keep the local content and retry after session-backed uploads are available."
        )
        #expect(
            ProviderDiagnosticErrorClassifier.classify(
                KDriveDirectUploadError.requiresUploadSession(maximumByteCount: maximum)
            ) == .validation
        )
        #expect(throws: Never.self) {
            try PotassiumKDriveService.validateDirectUploadByteCount(maximum)
        }
        #expect(throws: KDriveDirectUploadError.requiresUploadSession(
            maximumByteCount: maximum
        )) {
            try PotassiumKDriveService.validateDirectUploadByteCount(maximum + 1)
        }
        #expect(throws: KDriveDirectUploadError.fileSizeUnavailable) {
            try PotassiumKDriveService.validateDirectUploadByteCount(-1)
        }
        #expect(KDriveDirectUploadError.fileSizeUnavailable.recovery == .cannotSynchronize)
        #expect(KDriveDirectUploadError.fileSizeUnavailable.diagnosticCategory == .validation)
        #expect(
            KDriveDirectUploadError.fileSizeUnavailable.diagnosticSummary
                == "The callback file size could not be verified before direct upload."
        )
        #expect(
            KDriveDirectUploadError.fileSizeUnavailable.recoverySuggestion
                == "Keep the callback source available and retry once its size can be verified."
        )
    }

    @Test("Oversized callback files are rejected before content loading")
    func oversizedCallbackFileIsRejectedBeforeLoading() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fileURL = temporaryDirectory.appendingPathComponent("oversized.bin")
        #expect(FileManager.default.createFile(atPath: fileURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(
            atOffset: UInt64(PotassiumKDriveService.directUploadMaximumByteCount + 1)
        )
        try handle.close()

        #expect(throws: KDriveDirectUploadError.requiresUploadSession(
            maximumByteCount: PotassiumKDriveService.directUploadMaximumByteCount
        )) {
            _ = try KDriveDirectUploadContentLoader.loadContents(at: fileURL)
        }
    }

    @Test("Retryable HTTP rejections retain only a safe integer retry delay")
    func retryableHTTPRejectionsParseSafeRetryDelay() throws {
        let timeout = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(
                408,
                body: "timeout-detail",
                metadata: APIResponseMetadata(retryAfter: "3")
            )
        ))
        let throttled = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(
                429,
                body: "request quota reached",
                metadata: APIResponseMetadata(retryAfter: " 17 ")
            )
        ))

        #expect(timeout.recovery == .serverUnreachable)
        #expect(timeout.retryAfterSeconds == 3)
        #expect(throttled.recovery == .serverUnreachable)
        #expect(throttled.retryAfterSeconds == 17)
        #expect(throttled.diagnosticSummary == "The remote API rejected the operation. HTTP 429.")
        #expect(throttled.diagnosticSummary.contains("request quota reached") == false)
        #expect(throttled.diagnosticSummary.contains("17") == false)
        #expect(throttled.responseBodyPreview() == "request quota reached")
    }

    @Test("Non-integer Retry-After values are ignored")
    func nonIntegerRetryAfterValuesAreIgnored() throws {
        let malformed = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(
                429,
                body: "retry-later",
                metadata: APIResponseMetadata(retryAfter: "later")
            )
        ))
        let httpDate = try #require(KDriveRemoteErrorClassifier.apiRejection(
            from: APIClientError.unacceptableStatusCode(
                429,
                body: "retry-at-date",
                metadata: APIResponseMetadata(retryAfter: "Wed, 21 Oct 2015 07:28:00 GMT")
            )
        ))

        #expect(malformed.retryAfterSeconds == nil)
        #expect(httpDate.retryAfterSeconds == nil)
        #expect(malformed.recovery == .serverUnreachable)
        #expect(httpDate.recovery == .serverUnreachable)
        #expect(malformed.diagnosticSummary.contains(malformed.responseBody) == false)
        #expect(httpDate.diagnosticSummary.contains(httpDate.responseBody) == false)
    }

    private var evidenceBaseURL: URL {
        URL(string: "https://evidence.invalid")!
    }

    private func evidenceSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KDriveAPIEvidenceURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeService(
        returningShareLinkRight right: String
    ) async -> (PotassiumKDriveService, URLSession) {
        await KDriveAPIEvidenceURLProtocol.reset(returningShareLinkRight: right)
        let session = evidenceSession()
        let service = PotassiumKDriveService(
            bearerToken: "",
            apiBaseURL: evidenceBaseURL,
            session: session
        )
        return (service, session)
    }
}

private struct KDriveAPIEvidenceCapturedRequest: Sendable {
    let request: URLRequest
    let body: Data?
}

private actor KDriveAPIEvidenceTransportState {
    private var shareLinkRight = "inherit"
    private var requests: [KDriveAPIEvidenceCapturedRequest] = []

    func reset(returningShareLinkRight right: String) {
        shareLinkRight = right
        requests.removeAll()
    }

    func record(_ request: KDriveAPIEvidenceCapturedRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [KDriveAPIEvidenceCapturedRequest] {
        requests
    }

    func responseBody(for request: URLRequest) -> Data {
        if request.httpMethod == "PUT" {
            return Data(#"{"result":"success","data":true}"#.utf8)
        }

        if request.url?.path.hasSuffix("/duplicate") == true {
            return Data(
                """
                {
                  "result": "success",
                  "data": {
                    "id": 23,
                    "name": "Evidence copy.txt",
                    "type": "file",
                    "status": "active",
                    "visibility": "is_private_space",
                    "drive_id": 11,
                    "parent_id": 2,
                    "path": null,
                    "depth": 2,
                    "created_at": 1700000000,
                    "last_modified_at": 1700000000,
                    "updated_at": 1700000000,
                    "size": 0,
                    "mime_type": "text/plain",
                    "is_favorite": false
                  }
                }
                """.utf8
            )
        }

        let syntheticShareLink = ["https:", "", "share.invalid", "link"].joined(separator: "/")
        return Data(
            """
            {
              "result": "success",
              "data": {
                "url": "\(syntheticShareLink)",
                "file_id": 22,
                "right": "\(shareLinkRight)",
                "valid_until": null,
                "created_by": 1,
                "created_at": 1700000000,
                "updated_at": 1700000001,
                "capabilities": {
                  "can_edit": false,
                  "can_see_stats": false,
                  "can_see_info": true,
                  "can_download": true,
                  "can_comment": false,
                  "can_request_access": false
                },
                "access_blocked": false,
                "views": null
              }
            }
            """.utf8
        )
    }
}

private final class KDriveAPIEvidenceURLProtocol: URLProtocol {
    private static let state = KDriveAPIEvidenceTransportState()

    static func reset(returningShareLinkRight right: String) async {
        await state.reset(returningShareLinkRight: right)
    }

    static func recordedRequests() async -> [KDriveAPIEvidenceCapturedRequest] {
        await state.recordedRequests()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = request
        let captured = KDriveAPIEvidenceCapturedRequest(
            request: request,
            body: request.httpBody ?? Self.readBodyStream(from: request)
        )
        Task {
            await Self.state.record(captured)
            let data = await Self.state.responseBody(for: request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
