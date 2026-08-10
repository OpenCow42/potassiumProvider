import CryptoKit
import Foundation

public struct VaultRecoveryKit: Equatable, Sendable {
    public static let prefix = "KPV2"
    private static let magic = Data("KPR2".utf8)
    private static let payloadByteCount = 4 + 2 + 16 + 8 + 8 + 8 + VaultKeyMaterial.byteCount
    private static let checksumByteCount = 5

    public let vaultID: VaultIdentifier
    public let driveID: Int
    public let vaultRootFileID: Int
    public let vaultHeaderFileID: Int
    public let recoverySecret: VaultKeyMaterial

    public init(
        vaultID: VaultIdentifier,
        driveID: Int,
        vaultRootFileID: Int,
        vaultHeaderFileID: Int,
        recoverySecret: VaultKeyMaterial
    ) {
        self.vaultID = vaultID
        self.driveID = driveID
        self.vaultRootFileID = vaultRootFileID
        self.vaultHeaderFileID = vaultHeaderFileID
        self.recoverySecret = recoverySecret
    }

    public static func create(
        vaultID: VaultIdentifier,
        driveID: Int,
        vaultRootFileID: Int,
        vaultHeaderFileID: Int
    ) throws -> VaultRecoveryKit {
        VaultRecoveryKit(
            vaultID: vaultID,
            driveID: driveID,
            vaultRootFileID: vaultRootFileID,
            vaultHeaderFileID: vaultHeaderFileID,
            recoverySecret: try VaultKeyMaterial.random()
        )
    }

    public var encoded: String {
        var payload = Data()
        payload.append(Self.magic)
        payload.appendUInt16(VaultFormat.currentVersion)
        payload.append(vaultID.rawValue.data)
        payload.appendUInt64(UInt64(bitPattern: Int64(driveID)))
        payload.appendUInt64(UInt64(bitPattern: Int64(vaultRootFileID)))
        payload.appendUInt64(UInt64(bitPattern: Int64(vaultHeaderFileID)))
        payload.append(recoverySecret.data)
        payload.append(Data(SHA256.hash(data: payload)).prefix(Self.checksumByteCount))

        let base32 = VaultBase32.encode(payload)
        let groups = stride(from: 0, to: base32.count, by: 5).map { start -> String in
            let lower = base32.index(base32.startIndex, offsetBy: start)
            let upper = base32.index(
                lower,
                offsetBy: min(5, base32.count - start),
                limitedBy: base32.endIndex
            )!
            return String(base32[lower..<upper])
        }
        return ([Self.prefix] + groups).joined(separator: "-")
    }

    public init(encoded: String) throws {
        let normalized = encoded
            .uppercased()
            .split(separator: "-")
            .map(String.init)
        guard normalized.first == Self.prefix, normalized.count > 1,
              let decoded = VaultBase32.decode(normalized.dropFirst().joined()) else {
            throw VaultCryptoError.recoveryKitInvalid
        }
        guard decoded.count == Self.payloadByteCount + Self.checksumByteCount else {
            throw VaultCryptoError.recoveryKitInvalid
        }
        let payload = decoded.prefix(Self.payloadByteCount)
        let checksum = decoded.suffix(Self.checksumByteCount)
        guard Data(SHA256.hash(data: payload)).prefix(Self.checksumByteCount) == checksum else {
            throw VaultCryptoError.recoveryKitChecksumMismatch
        }

        var cursor = VaultDataCursor(data: Data(payload))
        guard try cursor.read(count: 4) == Self.magic else {
            throw VaultCryptoError.recoveryKitInvalid
        }
        let version = try cursor.readUInt16()
        guard version == VaultFormat.currentVersion else {
            throw VaultCryptoError.unsupportedFormatVersion(version)
        }
        vaultID = VaultIdentifier(rawValue: UUID(bytes: try cursor.read(count: 16)))
        driveID = Int(Int64(bitPattern: try cursor.readUInt64()))
        vaultRootFileID = Int(Int64(bitPattern: try cursor.readUInt64()))
        vaultHeaderFileID = Int(Int64(bitPattern: try cursor.readUInt64()))
        guard let secret = VaultKeyMaterial(data: try cursor.read(count: VaultKeyMaterial.byteCount)) else {
            throw VaultCryptoError.invalidKeyLength
        }
        recoverySecret = secret
    }
}

public enum VaultBootstrap {
    private static let magic = Data("KPB2".utf8)
    private static let headerByteCount = 4 + 2 + 4 + 16

    public struct RemoteLayout: Codable, Equatable, Sendable {
        public let contentContainerID: Int
        public let journalContainerID: Int
        public let checkpointContainerID: Int
        public let checkpointToken: String

        public init(
            contentContainerID: Int,
            journalContainerID: Int,
            checkpointContainerID: Int,
            checkpointToken: String
        ) {
            self.contentContainerID = contentContainerID
            self.journalContainerID = journalContainerID
            self.checkpointContainerID = checkpointContainerID
            self.checkpointToken = checkpointToken
        }
    }

    public struct Unlocked: Equatable, Sendable {
        public let vaultID: VaultIdentifier
        public let keyEpoch: UInt32
        public let rootKey: VaultKeyMaterial
        public let remoteLayout: RemoteLayout?
    }

    public struct Header: Equatable, Sendable {
        public let formatVersion: UInt16
        public let keyEpoch: UInt32
        public let vaultID: VaultIdentifier

        public init(
            formatVersion: UInt16,
            keyEpoch: UInt32,
            vaultID: VaultIdentifier
        ) {
            self.formatVersion = formatVersion
            self.keyEpoch = keyEpoch
            self.vaultID = vaultID
        }
    }

    public static func create(
        vaultID: VaultIdentifier,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch,
        rootKey: VaultKeyMaterial,
        recoverySecret: VaultKeyMaterial,
        remoteLayout: RemoteLayout? = nil
    ) throws -> Data {
        let header = makeHeader(vaultID: vaultID, keyEpoch: keyEpoch)
        let wrappingKey = recoveryWrappingKey(
            recoverySecret: recoverySecret,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        let payload = try VaultCoding.encoder.encode(BootstrapPayload(
            rootKey: rootKey.data,
            remoteLayout: remoteLayout
        ))
        let sealed = try AES.GCM.seal(
            payload,
            using: wrappingKey.symmetricKey,
            authenticating: header
        )
        guard let combined = sealed.combined else {
            throw VaultCryptoError.invalidEnvelope
        }
        return header + combined
    }

    public static func unlock(
        _ bootstrap: Data,
        recoverySecret: VaultKeyMaterial,
        expectedVaultID: VaultIdentifier? = nil
    ) throws -> Unlocked {
        let inspectedHeader = try inspectHeader(bootstrap)
        var cursor = VaultDataCursor(data: bootstrap)
        _ = try cursor.read(count: headerByteCount)
        let keyEpoch = inspectedHeader.keyEpoch
        let vaultID = inspectedHeader.vaultID
        if let expectedVaultID, expectedVaultID != vaultID {
            throw VaultCryptoError.unexpectedVault
        }
        let wrappingKey = recoveryWrappingKey(
            recoverySecret: recoverySecret,
            vaultID: vaultID,
            keyEpoch: keyEpoch
        )
        do {
            let box = try AES.GCM.SealedBox(combined: bootstrap.dropFirst(headerByteCount))
            let payloadData = try AES.GCM.open(
                box,
                using: wrappingKey.symmetricKey,
                authenticating: bootstrap.prefix(headerByteCount)
            )
            let payload = try VaultCoding.decoder.decode(
                BootstrapPayload.self,
                from: payloadData
            )
            guard let rootKey = VaultKeyMaterial(data: payload.rootKey) else {
                throw VaultCryptoError.invalidKeyLength
            }
            return Unlocked(
                vaultID: vaultID,
                keyEpoch: keyEpoch,
                rootKey: rootKey,
                remoteLayout: payload.remoteLayout
            )
        } catch let error as VaultCryptoError {
            throw error
        } catch {
            throw VaultCryptoError.authenticationFailed
        }
    }

    /// Reads only the fixed public bootstrap header. Callers must authenticate
    /// another vault object with the root key before trusting a cloud-access
    /// record based on this result.
    public static func inspectHeader(_ bootstrap: Data) throws -> Header {
        guard bootstrap.count > headerByteCount else {
            throw VaultCryptoError.invalidEnvelope
        }
        var cursor = VaultDataCursor(data: bootstrap)
        guard try cursor.read(count: 4) == magic else {
            throw VaultCryptoError.invalidEnvelopeMagic
        }
        let version = try cursor.readUInt16()
        guard version == VaultFormat.currentVersion else {
            throw VaultCryptoError.unsupportedFormatVersion(version)
        }
        return Header(
            formatVersion: version,
            keyEpoch: try cursor.readUInt32(),
            vaultID: VaultIdentifier(
                rawValue: UUID(bytes: try cursor.read(count: 16))
            )
        )
    }

    private static func makeHeader(vaultID: VaultIdentifier, keyEpoch: UInt32) -> Data {
        var header = Data()
        header.append(magic)
        header.appendUInt16(VaultFormat.currentVersion)
        header.appendUInt32(keyEpoch)
        header.append(vaultID.rawValue.data)
        return header
    }

    private static func recoveryWrappingKey(
        recoverySecret: VaultKeyMaterial,
        vaultID: VaultIdentifier,
        keyEpoch: UInt32
    ) -> VaultKeyMaterial {
        VaultCryptography.deriveKey(
            rootKey: recoverySecret,
            vaultID: vaultID,
            label: "recovery-wrap.epoch.\(keyEpoch)"
        )
    }

    private struct BootstrapPayload: Codable {
        let rootKey: Data
        let remoteLayout: RemoteLayout?
    }
}

enum VaultBase32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let decodeTable = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) }
    )

    static func encode(_ data: Data) -> String {
        var accumulator: UInt32 = 0
        var bits = 0
        var result = ""

        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((accumulator >> UInt32(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            result.append(alphabet[Int((accumulator << UInt32(5 - bits)) & 0x1F)])
        }
        return result
    }

    static func decode(_ value: String) -> Data? {
        var accumulator: UInt32 = 0
        var bits = 0
        var result = Data()

        for character in value {
            guard let decoded = decodeTable[character] else { return nil }
            accumulator = (accumulator << 5) | UInt32(decoded)
            bits += 5
            if bits >= 8 {
                bits -= 8
                result.append(UInt8((accumulator >> UInt32(bits)) & 0xFF))
            }
        }
        if bits > 0, accumulator & ((1 << UInt32(bits)) - 1) != 0 {
            return nil
        }
        return result
    }
}
