import Foundation
import PotassiumChannelCore
import PotassiumProviderCore
import Testing

struct ProviderDiagnosticValidationFieldTests {
    @Test func onlyKnownFieldClassesSurviveValidationParsing() throws {
        let error = APIClientError.unacceptableStatusCode(422,
            body: "{\"error\":{\"errors\":{\"with\":[\"PRIVATE_CANARY\"],\"PRIVATE_FIELD\":\"PRIVATE_VALUE\",\"actions\":[]}}}",
            metadata: APIResponseMetadata())
        let fields = ProviderDiagnosticValidationField.classify(error)
        #expect(fields == [.actions, .includedResources])
        let encoded = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE"))
    }

    @Test func unknownAndMalformedResponsesProduceNoFields() {
        for body in ["with PRIVATE_CANARY", "{\"error\":{\"message\":\"with\"}}", "{\"PRIVATE_FIELD\":1}"] {
            #expect(ProviderDiagnosticValidationField.classify(
                APIClientError.unacceptableStatusCode(422, body: body, metadata: APIResponseMetadata())) == nil)
        }
    }
}
