#if os(macOS) && STABILITY
import Foundation
import PotassiumProviderCore
import Security

enum StabilityAppGroupProvisioningError: Error {
    case unreadableSignature, unreadableProfile, unauthorizedGroup, invalidApplicationIdentity, expiredProfile
}

/// A valid code signature alone does not authorize macOS app-group access.
/// Keep the qualification read-only and never export the profile or its identifiers.
enum StabilityAppGroupProvisioning {
    static func verify(appURL: URL) throws {
        for (role, url) in [
            ("app", appURL),
            ("provider", appURL.appendingPathComponent("Contents/PlugIns/potassiumProviderFileProvider.appex")),
            ("actions", appURL.appendingPathComponent("Contents/PlugIns/potassiumProviderActions.appex")),
        ] {
            do { try verifyBundle(at: url) }
            catch {
                print("finder stability preflight: \(role) app-group provisioning failed; rebuild with registered App Groups and updated provisioning profiles")
                throw error
            }
        }
    }

    private static func verifyBundle(at url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else {
            throw StabilityAppGroupProvisioningError.unreadableSignature
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let bundleIdentifier = Bundle(url: url)?.bundleIdentifier else {
            throw StabilityAppGroupProvisioningError.unreadableSignature
        }
        let profileURL = url.appendingPathComponent("Contents/embedded.provisionprofile")
        guard let size = try? profileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 1_024 * 1_024, let data = try? Data(contentsOf: profileURL) else {
            throw StabilityAppGroupProvisioningError.unreadableProfile
        }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder,
              data.withUnsafeBytes({ bytes in
                  guard let base = bytes.baseAddress else { return errSecDecode }
                  return CMSDecoderUpdateMessage(decoder, base, bytes.count)
              }) == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw StabilityAppGroupProvisioningError.unreadableProfile
        }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content,
              let profile = try PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any] else {
            throw StabilityAppGroupProvisioningError.unreadableProfile
        }
        // This qualifies the installed profile's claims; macOS remains the
        // authority for CMS trust, device eligibility and runtime validation.
        try validate(entitlements: entitlements, profile: profile, bundleIdentifier: bundleIdentifier)
    }

    static func validate(entitlements: [String: Any], profile: [String: Any], bundleIdentifier: String, now: Date = Date()) throws {
        guard let grants = profile["Entitlements"] as? [String: Any],
              let expiration = profile["ExpirationDate"] as? Date else {
            throw StabilityAppGroupProvisioningError.unreadableProfile
        }
        guard expiration > now else { throw StabilityAppGroupProvisioningError.expiredProfile }
        guard let team = entitlements["com.apple.developer.team-identifier"] as? String, !team.isEmpty,
              let application = entitlements["com.apple.application-identifier"] as? String,
              !application.contains("$("), application == team + "." + bundleIdentifier,
              grants["com.apple.application-identifier"] as? String == application,
              grants["com.apple.developer.team-identifier"] as? String == team else {
            throw StabilityAppGroupProvisioningError.invalidApplicationIdentity
        }
        let group = ProviderConstants.appGroupIdentifier
        guard (entitlements["com.apple.security.application-groups"] as? [String])?.contains(group) == true,
              (grants["com.apple.security.application-groups"] as? [String])?.contains(group) == true else {
            throw StabilityAppGroupProvisioningError.unauthorizedGroup
        }
    }
}
#endif
