import CryptoKit
import Foundation

public struct VaultContentEncryptionContext: Equatable, Sendable {
    public let vaultID: VaultIdentifier
    public let itemID: VaultItemIdentifier
    public let contentRevision: VaultRevision
    public let objectToken: String
    public let keyEpoch: UInt32

    public init(
        vaultID: VaultIdentifier,
        itemID: VaultItemIdentifier,
        contentRevision: VaultRevision,
        objectToken: String,
        keyEpoch: UInt32 = VaultFormat.currentKeyEpoch
    ) {
        self.vaultID = vaultID
        self.itemID = itemID
        self.contentRevision = contentRevision
        self.objectToken = objectToken
        self.keyEpoch = keyEpoch
    }
}

public struct VaultContentEncryptionResult: Equatable, Sendable {
    public let contentKey: VaultKeyMaterial
    public let noncePrefix: UInt64
    public let plaintextLength: Int64
    public let plaintextDigest: Data
    public let frameCount: UInt32
    public let ciphertextLength: Int64

    public init(
        contentKey: VaultKeyMaterial,
        noncePrefix: UInt64,
        plaintextLength: Int64,
        plaintextDigest: Data,
        frameCount: UInt32,
        ciphertextLength: Int64
    ) {
        self.contentKey = contentKey
        self.noncePrefix = noncePrefix
        self.plaintextLength = plaintextLength
        self.plaintextDigest = plaintextDigest
        self.frameCount = frameCount
        self.ciphertextLength = ciphertextLength
    }
}

public enum VaultContentCipher {
    private static let magic = Data("KPC2".utf8)
    private static let headerByteCount = 4 + 2 + 4 + 8
    private static let authenticationTagByteCount = 16

    public static func encrypt(
        plaintextURL: URL,
        ciphertextURL: URL,
        context: VaultContentEncryptionContext,
        contentKey suppliedContentKey: VaultKeyMaterial? = nil,
        noncePrefix suppliedNoncePrefix: UInt64? = nil
    ) throws -> VaultContentEncryptionResult {
        let contentKey = try suppliedContentKey ?? VaultKeyMaterial.random()
        let noncePrefix = try suppliedNoncePrefix ?? VaultRandom.uint64()
        let sourceSize = try plaintextURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize.map(Int64.init) ?? 0
        let maximumPlaintextSize =
            Int64(UInt32.max) * Int64(VaultFormat.contentFrameSize)
        guard sourceSize <= maximumPlaintextSize else {
            throw VaultCryptoError.frameLimitExceeded
        }
        let input = try FileHandle(forReadingFrom: plaintextURL)
        try prepareOutputFile(at: ciphertextURL)
        let output = try FileHandle(forWritingTo: ciphertextURL)
        var completed = false

        defer {
            try? input.close()
            try? output.close()
            if completed == false {
                try? FileManager.default.removeItem(at: ciphertextURL)
            }
        }

        var header = Data()
        header.append(magic)
        header.appendUInt16(VaultFormat.currentVersion)
        header.appendUInt32(UInt32(VaultFormat.contentFrameSize))
        header.appendUInt64(noncePrefix)
        try output.write(contentsOf: header)

        var hasher = SHA256()
        var plaintextLength: Int64 = 0
        var frameIndex: UInt32 = 0
        var current = try input.read(upToCount: VaultFormat.contentFrameSize) ?? Data()

        while true {
            try Task.checkCancellation()
            guard frameIndex < UInt32.max else {
                throw VaultCryptoError.frameLimitExceeded
            }
            let next = try input.read(upToCount: VaultFormat.contentFrameSize) ?? Data()
            let isFinal = next.isEmpty
            let unpaddedCount = current.count
            plaintextLength += Int64(unpaddedCount)
            hasher.update(data: current)

            let padded: Data
            if isFinal {
                padded = try paddedFinalFrame(current)
            } else {
                guard current.count == VaultFormat.contentFrameSize else {
                    throw VaultCryptoError.invalidFrame
                }
                padded = current
            }

            let nonce = try frameNonce(prefix: noncePrefix, index: frameIndex)
            let associatedData = try frameAssociatedData(
                context: context,
                frameIndex: frameIndex,
                paddedLength: padded.count,
                isFinal: isFinal
            )
            let sealed = try AES.GCM.seal(
                padded,
                using: contentKey.symmetricKey,
                nonce: nonce,
                authenticating: associatedData
            )
            var frame = Data()
            frame.append(sealed.ciphertext)
            frame.append(sealed.tag)
            guard frame.count <= Int(UInt32.max) else {
                throw VaultCryptoError.invalidFrame
            }
            var frameHeader = Data()
            frameHeader.appendUInt32(UInt32(frame.count))
            try output.write(contentsOf: frameHeader)
            try output.write(contentsOf: frame)
            frameIndex += 1

            if isFinal {
                break
            }
            current = next
        }

        try output.synchronize()
        let ciphertextLength = try output.offset()
        completed = true
        return VaultContentEncryptionResult(
            contentKey: contentKey,
            noncePrefix: noncePrefix,
            plaintextLength: plaintextLength,
            plaintextDigest: Data(hasher.finalize()),
            frameCount: frameIndex,
            ciphertextLength: Int64(ciphertextLength)
        )
    }

    public static func decrypt(
        ciphertextURL: URL,
        plaintextURL: URL,
        context: VaultContentEncryptionContext,
        contentKey: VaultKeyMaterial,
        expectedNoncePrefix: UInt64,
        expectedPlaintextLength: Int64,
        expectedPlaintextDigest: Data,
        expectedFrameCount: UInt32
    ) throws {
        guard expectedPlaintextLength >= 0,
              expectedPlaintextDigest.count == SHA256.Digest.byteCount else {
            throw VaultCryptoError.invalidLength
        }
        let frameSize = Int64(VaultFormat.contentFrameSize)
        let expectedCount = max(
            1,
            expectedPlaintextLength / frameSize
                + (expectedPlaintextLength.isMultiple(of: frameSize) ? 0 : 1)
        )
        guard expectedCount <= Int64(UInt32.max),
              expectedFrameCount == UInt32(expectedCount) else {
            throw VaultCryptoError.invalidFrame
        }
        let input = try FileHandle(forReadingFrom: ciphertextURL)
        try prepareOutputFile(at: plaintextURL)
        let output = try FileHandle(forWritingTo: plaintextURL)
        var completed = false

        defer {
            try? input.close()
            try? output.close()
            if completed == false {
                try? FileManager.default.removeItem(at: plaintextURL)
            }
        }

        let header = try readExactly(headerByteCount, from: input)
        var cursor = VaultDataCursor(data: header)
        guard try cursor.read(count: 4) == magic else {
            throw VaultCryptoError.invalidEnvelopeMagic
        }
        let version = try cursor.readUInt16()
        guard version == VaultFormat.currentVersion else {
            throw VaultCryptoError.unsupportedFormatVersion(version)
        }
        guard try cursor.readUInt32() == UInt32(VaultFormat.contentFrameSize) else {
            throw VaultCryptoError.invalidFrame
        }
        let noncePrefix = try cursor.readUInt64()
        guard noncePrefix == expectedNoncePrefix else {
            throw VaultCryptoError.authenticationFailed
        }

        var hasher = SHA256()
        var plaintextLength: Int64 = 0
        var frameIndex: UInt32 = 0

        while frameIndex < expectedFrameCount {
            try Task.checkCancellation()
            let frameLengthData = try readExactly(4, from: input)
            var frameLengthCursor = VaultDataCursor(data: frameLengthData)
            let frameLength = Int(try frameLengthCursor.readUInt32())
            guard frameLength >= authenticationTagByteCount,
                  frameLength <= VaultFormat.contentFrameSize + authenticationTagByteCount else {
                throw VaultCryptoError.invalidFrame
            }
            let frame = try readExactly(frameLength, from: input)
            let ciphertext = frame.dropLast(authenticationTagByteCount)
            let tag = frame.suffix(authenticationTagByteCount)
            let isFinal = frameIndex == expectedFrameCount - 1
            let associatedData = try frameAssociatedData(
                context: context,
                frameIndex: frameIndex,
                paddedLength: ciphertext.count,
                isFinal: isFinal
            )
            let nonce = try frameNonce(prefix: noncePrefix, index: frameIndex)
            let sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let padded: Data
            do {
                padded = try AES.GCM.open(
                    sealed,
                    using: contentKey.symmetricKey,
                    authenticating: associatedData
                )
            } catch {
                throw VaultCryptoError.authenticationFailed
            }

            let remaining = expectedPlaintextLength - plaintextLength
            guard remaining >= 0 else {
                throw VaultCryptoError.contentLengthMismatch
            }
            let unpaddedLength = isFinal
                ? min(Int64(padded.count), remaining)
                : Int64(padded.count)
            guard isFinal || padded.count == VaultFormat.contentFrameSize,
                  unpaddedLength >= 0,
                  unpaddedLength <= Int64(padded.count) else {
                throw VaultCryptoError.invalidFrame
            }
            if isFinal {
                let expectedPaddedLength = paddedFinalFrameSize(
                    for: Int(unpaddedLength)
                )
                guard padded.count == expectedPaddedLength else {
                    throw VaultCryptoError.invalidFrame
                }
            }
            let plaintext = padded.prefix(Int(unpaddedLength))
            hasher.update(data: plaintext)
            try output.write(contentsOf: plaintext)
            plaintextLength += unpaddedLength
            frameIndex += 1
        }

        let trailing = try input.read(upToCount: 1) ?? Data()
        guard trailing.isEmpty else {
            throw VaultCryptoError.invalidFrame
        }
        guard plaintextLength == expectedPlaintextLength else {
            throw VaultCryptoError.contentLengthMismatch
        }
        guard Data(hasher.finalize()) == expectedPlaintextDigest else {
            throw VaultCryptoError.contentDigestMismatch
        }

        try output.synchronize()
        completed = true
    }

    public static func paddedFinalFrameSize(for plaintextByteCount: Int) -> Int {
        let required = max(plaintextByteCount, VaultFormat.minimumFinalFrameSize)
        var bucket = VaultFormat.minimumFinalFrameSize
        while bucket < required, bucket < VaultFormat.contentFrameSize {
            bucket *= 2
        }
        return min(bucket, VaultFormat.contentFrameSize)
    }

    private static func paddedFinalFrame(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= VaultFormat.contentFrameSize else {
            throw VaultCryptoError.invalidFrame
        }
        let targetSize = paddedFinalFrameSize(for: plaintext.count)
        var result = plaintext
        if targetSize > plaintext.count {
            result.append(try VaultRandom.bytes(count: targetSize - plaintext.count))
        }
        return result
    }

    private static func frameNonce(prefix: UInt64, index: UInt32) throws -> AES.GCM.Nonce {
        var data = Data()
        data.appendUInt64(prefix)
        data.appendUInt32(index)
        return try AES.GCM.Nonce(data: data)
    }

    private static func frameAssociatedData(
        context: VaultContentEncryptionContext,
        frameIndex: UInt32,
        paddedLength: Int,
        isFinal: Bool
    ) throws -> Data {
        guard let token = Data(base64URLEncoded: context.objectToken), token.count == 20 else {
            throw VaultCryptoError.invalidObjectToken
        }
        var data = magic
        data.appendUInt16(VaultFormat.currentVersion)
        data.appendUInt32(context.keyEpoch)
        data.append(context.vaultID.rawValue.data)
        data.append(context.itemID.rawValue.data)
        data.append(context.contentRevision.data)
        data.append(token)
        data.appendUInt32(frameIndex)
        data.appendUInt32(UInt32(paddedLength))
        data.append(isFinal ? 1 : 0)
        return data
    }

    private static func prepareOutputFile(at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        guard manager.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        #if canImport(Darwin)
        try manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        guard count >= 0 else {
            throw VaultCryptoError.invalidLength
        }
        var result = Data()
        while result.count < count {
            let chunk = try handle.read(upToCount: count - result.count) ?? Data()
            guard chunk.isEmpty == false else {
                throw VaultCryptoError.invalidFrame
            }
            result.append(chunk)
        }
        return result
    }
}
