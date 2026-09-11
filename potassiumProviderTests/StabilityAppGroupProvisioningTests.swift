#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore
import Testing
@testable import potassiumProvider

struct StabilityAppGroupProvisioningTests {
    private let bundleIdentifier = "test.provider.Actions"
    private let now = Date(timeIntervalSince1970: 1_000)
    private var entitlements: [String: Any] { [
        "com.apple.application-identifier": "TESTTEAM.test.provider.Actions",
        "com.apple.developer.team-identifier": "TESTTEAM",
        "com.apple.security.application-groups": [ProviderConstants.appGroupIdentifier],
    ] }
    private func profile(_ grants: [String: Any]) -> [String: Any] {
        ["Entitlements": grants, "ExpirationDate": now.addingTimeInterval(60)]
    }

    @Test func explicitIdentityWithAuthorizedGroupPasses() throws {
        try StabilityAppGroupProvisioning.validate(entitlements: entitlements, profile: profile(entitlements), bundleIdentifier: bundleIdentifier, now: now)
    }

    @Test(arguments: ["missing", "different", "wildcard"])
    func claimedGroupWithoutExactProfileAuthorizationFails(kind: String) {
        var grants = entitlements
        grants["com.apple.security.application-groups"] = switch kind {
        case "missing": nil
        case "different": ["group.test.unrelated"]
        default: ["TESTTEAM.*"]
        }
        #expect(throws: StabilityAppGroupProvisioningError.unauthorizedGroup) {
            try StabilityAppGroupProvisioning.validate(entitlements: entitlements, profile: profile(grants), bundleIdentifier: bundleIdentifier, now: now)
        }
    }

    @Test(arguments: ["TESTTEAM.*", "TESTTEAM.test.other", "$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"])
    func wildcardWrongOrUnexpandedApplicationIdentityFails(identity: String) {
        var grants = entitlements
        grants["com.apple.application-identifier"] = identity
        #expect(throws: StabilityAppGroupProvisioningError.invalidApplicationIdentity) {
            try StabilityAppGroupProvisioning.validate(entitlements: entitlements, profile: profile(grants), bundleIdentifier: bundleIdentifier, now: now)
        }
    }

    @Test func expiredMalformedAndUnsignedGroupClaimsFail() {
        #expect(throws: StabilityAppGroupProvisioningError.expiredProfile) {
            try StabilityAppGroupProvisioning.validate(entitlements: entitlements, profile: profile(entitlements), bundleIdentifier: bundleIdentifier, now: now.addingTimeInterval(60))
        }
        #expect(throws: StabilityAppGroupProvisioningError.unreadableProfile) {
            try StabilityAppGroupProvisioning.validate(entitlements: entitlements, profile: [:], bundleIdentifier: bundleIdentifier, now: now)
        }
        var missing = entitlements
        missing.removeValue(forKey: "com.apple.security.application-groups")
        #expect(throws: StabilityAppGroupProvisioningError.unauthorizedGroup) {
            try StabilityAppGroupProvisioning.validate(entitlements: missing, profile: profile(entitlements), bundleIdentifier: bundleIdentifier, now: now)
        }
    }
}
#endif
