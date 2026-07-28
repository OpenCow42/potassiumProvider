import Foundation
@testable import PotassiumProviderCore
import Testing

struct KDriveObjectStoreLeakageTests {
    @Test func opaqueUploadRequestContainsNoLogicalMetadata() async throws {
        let token = Data(0..<20).opaqueTokenForTest
        let store = PotassiumKDriveObjectStore(
            driveID: 42,
            bearerToken: "redacted-bearer-token",
            apiBaseURL: URL(string: "https://api.example.test")!
        )
        let request = try await store.uploadRequest(
            containerID: 73,
            token: token,
            byteCount: 65_536
        )
        let observableRequest = [
            request.url?.absoluteString ?? "",
            request.allHTTPHeaderFields?
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: "\n") ?? "",
            request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "",
        ].joined(separator: "\n")

        for forbidden in [
            "Quarterly Plan.pdf",
            "/Private/Alice Mac/Desktop",
            ".pdf",
            "application/pdf",
            "2026-07-28",
            "plaintext-sha256",
            "Alice Mac",
            "highly private body bytes",
        ] {
            #expect(observableRequest.contains(forbidden) == false)
        }
        #expect(request.url?.query?.contains("file_name=\(token).bin") == true)
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/octet-stream"
        )
        #expect(request.httpBody == nil)
    }
}

private extension Data {
    var opaqueTokenForTest: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
