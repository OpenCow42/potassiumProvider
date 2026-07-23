import Foundation
import PotassiumProviderCore
import Testing

struct ProviderExternalDomainBindingTests {
    @Test func codecRoundTripsOpaqueConfigurationIdentifier() throws {
        let userInfo = ProviderExternalDomainUserInfoCodec.userInfo(
            configurationIdentifier: "configuration-1"
        )

        #expect(
            userInfo[ProviderExternalDomainUserInfoCodec.schemaVersionKey] as? NSNumber
                == NSNumber(value: ProviderExternalDomainUserInfoCodec.currentSchemaVersion)
        )
        #expect(
            try ProviderExternalDomainUserInfoCodec.decode(userInfo)
                == ProviderExternalDomainBinding(configurationIdentifier: "configuration-1")
        )
    }

    @Test func codecRecognizesPartialBindingWithoutAcceptingIt() {
        let userInfo: [AnyHashable: Any] = [
            ProviderExternalDomainUserInfoCodec.configurationIdentifierKey: "configuration-1"
        ]

        #expect(ProviderExternalDomainUserInfoCodec.containsBinding(in: userInfo))
        #expect(throws: ProviderExternalDomainBindingDecodingError.unsupportedSchema) {
            try ProviderExternalDomainUserInfoCodec.decode(userInfo)
        }
    }

    @Test func codecRejectsUnknownSchemaAndBlankIdentifier() {
        let unknownSchema: [AnyHashable: Any] = [
            ProviderExternalDomainUserInfoCodec.schemaVersionKey: NSNumber(value: 2),
            ProviderExternalDomainUserInfoCodec.configurationIdentifierKey: "configuration-1",
        ]
        #expect(throws: ProviderExternalDomainBindingDecodingError.unsupportedSchema) {
            try ProviderExternalDomainUserInfoCodec.decode(unknownSchema)
        }

        let blankIdentifier: [AnyHashable: Any] = [
            ProviderExternalDomainUserInfoCodec.schemaVersionKey: NSNumber(value: 1),
            ProviderExternalDomainUserInfoCodec.configurationIdentifierKey: "   ",
        ]
        #expect(throws: ProviderExternalDomainBindingDecodingError.missingConfigurationIdentifier) {
            try ProviderExternalDomainUserInfoCodec.decode(blankIdentifier)
        }
    }
}
