import CryptoKit
import Foundation
import Security

public enum VaultCryptoError: Error, Equatable, LocalizedError, Sendable {
    case invalidKeyLength
    case invalidLength
    case invalidObjectToken
    case invalidEnvelope
    case invalidEnvelopeMagic
    case unsupportedFormatVersion(UInt16)
    case unexpectedObjectRole
    case unexpectedVault
    case authenticationFailed
    case randomGenerationFailed(OSStatus)
    case frameLimitExceeded
    case invalidFrame
    case contentLengthMismatch
    case contentDigestMismatch
    case recoveryKitInvalid
    case recoveryKitChecksumMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength:
            return "The vault key has an invalid length."
        case .invalidLength:
            return "The encrypted value has an invalid length."
        case .invalidObjectToken:
            return "The encrypted object token is invalid."
        case .invalidEnvelope:
            return "The encrypted vault envelope is malformed."
        case .invalidEnvelopeMagic:
            return "The encrypted vault envelope has an invalid format marker."
        case .unsupportedFormatVersion(let version):
            return "Vault format version \(version) is not supported."
        case .unexpectedObjectRole:
            return "The encrypted object has an unexpected role."
        case .unexpectedVault:
            return "The encrypted object belongs to a different vault."
        case .authenticationFailed:
            return "The encrypted object failed authentication."
        case .randomGenerationFailed(let status):
            return "Secure random generation failed with status \(status)."
        case .frameLimitExceeded:
            return "The file is too large for the vault content format."
        case .invalidFrame:
            return "The encrypted content contains an invalid frame."
        case .contentLengthMismatch:
            return "The decrypted content length does not match its authenticated metadata."
        case .contentDigestMismatch:
            return "The decrypted content digest does not match its authenticated metadata."
        case .recoveryKitInvalid:
            return "The recovery kit is malformed."
        case .recoveryKitChecksumMismatch:
            return "The recovery kit checksum is invalid."
        }
    }
}

public enum VaultCryptography {
    private static let envelopeMagic = Data("KPE1".utf8)
    private static let envelopeHeaderByteCount = 4 + 2 + 1 + 4 + 16 + 20

    public static func makeRootKey() throws -> VaultKeyMaterial {
        try VaultKeyMaterial.random()
    }

    public static func makeObjectToken() throws -> String {
        try VaultRandom.bytes(count: 20).vaultBase64URLEncodedString()
    }

    public static func makeObjectToken(
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier
    ) throws -> String {
        let namingKey = deriveKey(
            rootKey: rootKey,
            vaultID: vaultID,
            label: "object-name"
        )
        let randomInput = try VaultRandom.bytes(count: 32)
        let digest = HMAC<SHA256>.authenticationCode(
            for: randomInput,
            using: namingKey.symmetricKey
        )
        return Data(digest.prefix(20)).vaultBase64URLEncodedString()
    }

    public static func deriveKey(
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        label: String,
        salt: Data = Data(),
        outputByteCount: Int = VaultKeyMaterial.byteCount
    ) -> VaultKeyMaterial {
        let contextSalt = vaultID.rawValue.data + salt
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: rootKey.symmetricKey,
            salt: contextSalt,
            info: Data("net.weavee.potassiumProvider.vault.\(label)".utf8),
            outputByteCount: outputByteCount
        )
        let data = key.withUnsafeBytes { Data($0) }
        return VaultKeyMaterial(data: data)!
    }

    public static func seal<Value: Encodable>(
        _ value: Value,
        role: VaultObjectRole,
        objectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> Data {
        let plaintext = try VaultCoding.encoder.encode(value)
        return try seal(
            plaintext,
            role: role,
            objectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
    }

    public static func seal(
        _ plaintext: Data,
        role: VaultObjectRole,
        objectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> Data {
        let token = try objectTokenData(objectToken)
        let header = envelopeHeader(
            role: role,
            keyEpoch: keyEpoch,
            vaultID: vaultID,
            objectToken: token
        )
        let objectKey = deriveKey(
            rootKey: rootKey,
            vaultID: vaultID,
            label: "object.\(role.rawValue).epoch.\(keyEpoch)",
            salt: token
        )
        do {
            let sealed = try AES.GCM.seal(
                plaintext,
                using: objectKey.symmetricKey,
                authenticating: header
            )
            guard let combined = sealed.combined else {
                throw VaultCryptoError.invalidEnvelope
            }
            return header + combined
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    public static func open<Value: Decodable>(
        _ type: Value.Type,
        envelope: Data,
        expectedRole: VaultObjectRole,
        expectedObjectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> Value {
        let plaintext = try open(
            envelope,
            expectedRole: expectedRole,
            expectedObjectToken: expectedObjectToken,
            rootKey: rootKey,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        return try VaultCoding.decoder.decode(type, from: plaintext)
    }

    public static func open(
        _ envelope: Data,
        expectedRole: VaultObjectRole,
        expectedObjectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> Data {
        guard envelope.count > envelopeHeaderByteCount else {
            throw VaultCryptoError.invalidEnvelope
        }
        var cursor = VaultDataCursor(data: envelope)
        guard try cursor.read(count: 4) == envelopeMagic else {
            throw VaultCryptoError.invalidEnvelopeMagic
        }
        let version = try cursor.readUInt16()
        guard version == VaultFormat.currentVersion else {
            throw VaultCryptoError.unsupportedFormatVersion(version)
        }
        guard let role = VaultObjectRole(rawValue: try cursor.readUInt8()),
              role == expectedRole else {
            throw VaultCryptoError.unexpectedObjectRole
        }
        let envelopeEpoch = try cursor.readUInt32()
        guard envelopeEpoch == keyEpoch else {
            throw VaultCryptoError.authenticationFailed
        }
        let envelopeVaultID = VaultIdentifier(rawValue: UUID(bytes: try cursor.read(count: 16)))
        guard envelopeVaultID == vaultID else {
            throw VaultCryptoError.unexpectedVault
        }
        let token = try cursor.read(count: 20)
        guard token == (try objectTokenData(expectedObjectToken)) else {
            throw VaultCryptoError.invalidObjectToken
        }
        let header = envelope.prefix(envelopeHeaderByteCount)
        let objectKey = deriveKey(
            rootKey: rootKey,
            vaultID: vaultID,
            label: "object.\(role.rawValue).epoch.\(envelopeEpoch)",
            salt: token
        )

        do {
            let sealedBox = try AES.GCM.SealedBox(combined: envelope.dropFirst(envelopeHeaderByteCount))
            return try AES.GCM.open(
                sealedBox,
                using: objectKey.symmetricKey,
                authenticating: header
            )
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    public static func wrapContentKey(
        _ contentKey: VaultKeyMaterial,
        objectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> Data {
        let token = try objectTokenData(objectToken)
        let wrappingKey = deriveKey(
            rootKey: rootKey,
            vaultID: vaultID,
            label: "content-wrap.epoch.\(keyEpoch)",
            salt: token
        )
        let associatedData = contentKeyAssociatedData(
            vaultID: vaultID,
            keyEpoch: keyEpoch,
            objectToken: token
        )
        let sealed = try AES.GCM.seal(
            contentKey.data,
            using: wrappingKey.symmetricKey,
            authenticating: associatedData
        )
        guard let combined = sealed.combined else {
            throw VaultCryptoError.invalidEnvelope
        }
        return combined
    }

    public static func unwrapContentKey(
        _ wrappedKey: Data,
        objectToken: String,
        rootKey: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) throws -> VaultKeyMaterial {
        let token = try objectTokenData(objectToken)
        let wrappingKey = deriveKey(
            rootKey: rootKey,
            vaultID: vaultID,
            label: "content-wrap.epoch.\(keyEpoch)",
            salt: token
        )
        let associatedData = contentKeyAssociatedData(
            vaultID: vaultID,
            keyEpoch: keyEpoch,
            objectToken: token
        )
        do {
            let sealed = try AES.GCM.SealedBox(combined: wrappedKey)
            let data = try AES.GCM.open(
                sealed,
                using: wrappingKey.symmetricKey,
                authenticating: associatedData
            )
            guard let key = VaultKeyMaterial(data: data) else {
                throw VaultCryptoError.invalidKeyLength
            }
            return key
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    public static func revision<Value: Encodable>(for value: Value) throws -> VaultRevision {
        VaultRevision(hashing: try VaultCoding.encoder.encode(value))
    }

    private static func objectTokenData(_ value: String) throws -> Data {
        guard let token = Data(base64URLEncoded: value), token.count == 20 else {
            throw VaultCryptoError.invalidObjectToken
        }
        return token
    }

    private static func envelopeHeader(
        role: VaultObjectRole,
        keyEpoch: UInt32,
        vaultID: VaultIdentifier,
        objectToken: Data
    ) -> Data {
        var result = Data()
        result.append(envelopeMagic)
        result.appendUInt16(VaultFormat.currentVersion)
        result.append(role.rawValue)
        result.appendUInt32(keyEpoch)
        result.append(vaultID.rawValue.data)
        result.append(objectToken)
        return result
    }

    private static func contentKeyAssociatedData(
        vaultID: VaultIdentifier,
        keyEpoch: UInt32,
        objectToken: Data
    ) -> Data {
        var data = Data("KPW1".utf8)
        data.appendUInt16(VaultFormat.currentVersion)
        data.appendUInt32(keyEpoch)
        data.append(vaultID.rawValue.data)
        data.append(objectToken)
        return data
    }
}

enum VaultCoding {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

struct VaultDataCursor {
    let data: Data
    private(set) var offset = 0

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw VaultCryptoError.invalidLength
        }
        let result = data.subdata(in: offset..<(offset + count))
        offset += count
        return result
    }

    mutating func readUInt8() throws -> UInt8 {
        try read(count: 1)[0]
    }

    mutating func readUInt16() throws -> UInt16 {
        try read(count: 2).withUnsafeBytes {
            UInt16(bigEndian: $0.loadUnaligned(as: UInt16.self))
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        try read(count: 4).withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        try read(count: 8).withUnsafeBytes {
            UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self))
        }
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }
}
