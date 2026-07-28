import CryptoKit
import Foundation
@testable import PotassiumProviderCore
import Testing

struct VaultCryptographyTests {
    @Test func hkdfDerivationMatchesFrozenVector() {
        let key = VaultCryptography.deriveKey(
            rootKey: VaultKeyMaterial(data: Data(repeating: 0x0B, count: 32))!,
            vaultID: VaultIdentifier(
                rawValue: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
            ),
            label: "metadata",
            salt: Data((0...12).map(UInt8.init))
        )
        #expect(
            key.data.hex
                == "a8558f162164c1b7179ca27f2de10d10bf6a920c4c42b4570967ef9c143aa006"
        )
    }

    @Test func aesGCMMatchesNISTKnownAnswerVector() throws {
        let key = SymmetricKey(data: Data(repeating: 0, count: 32))
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 0, count: 12))
        let sealed = try AES.GCM.seal(
            Data(repeating: 0, count: 16),
            using: key,
            nonce: nonce
        )
        #expect(sealed.ciphertext.hex == "cea7403d4d606b6e074ec5d3baf39d18")
        #expect(sealed.tag.hex == "d0d1c8a799996bf0265b98b5d48ab919")
    }

    @Test func fileProviderItemIdentifierRoundTrips() {
        let identifier = VaultItemIdentifier(
            rawValue: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!
        )

        #expect(
            VaultItemIdentifier(fileProviderIdentifier: identifier.fileProviderIdentifier)
                == identifier
        )
        #expect(VaultItemIdentifier(fileProviderIdentifier: "42") == nil)
        #expect(VaultItemIdentifier(fileProviderIdentifier: "ev1:not-base64") == nil)
    }

    @Test func encryptedEnvelopeRoundTripsAndBindsContext() throws {
        let vaultID = VaultIdentifier(
            rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        )
        let otherVaultID = VaultIdentifier(
            rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let rootKey = VaultKeyMaterial(data: Data(repeating: 0x11, count: 32))!
        let tokenData = Data(0..<20)
        let token = tokenData.vaultBase64URLEncodedString()
        let value = Fixture(message: "private-name.txt", count: 42)

        let encrypted = try VaultCryptography.seal(
            value,
            role: .metadata,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultID
        )
        let randomized = try VaultCryptography.seal(
            value,
            role: .metadata,
            objectToken: token,
            rootKey: rootKey,
            vaultID: vaultID
        )
        #expect(encrypted != randomized)
        #expect(encrypted.range(of: Data(value.message.utf8)) == nil)

        let opened = try VaultCryptography.open(
            Fixture.self,
            envelope: encrypted,
            expectedRole: .metadata,
            expectedObjectToken: token,
            rootKey: rootKey,
            vaultID: vaultID
        )
        #expect(opened == value)

        #expect(throws: VaultCryptoError.unexpectedObjectRole) {
            try VaultCryptography.open(
                Fixture.self,
                envelope: encrypted,
                expectedRole: .transaction,
                expectedObjectToken: token,
                rootKey: rootKey,
                vaultID: vaultID
            )
        }
        #expect(throws: VaultCryptoError.unexpectedVault) {
            try VaultCryptography.open(
                Fixture.self,
                envelope: encrypted,
                expectedRole: .metadata,
                expectedObjectToken: token,
                rootKey: rootKey,
                vaultID: otherVaultID
            )
        }

        var tampered = encrypted
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        #expect(throws: VaultCryptoError.authenticationFailed) {
            try VaultCryptography.open(
                Fixture.self,
                envelope: tampered,
                expectedRole: .metadata,
                expectedObjectToken: token,
                rootKey: rootKey,
                vaultID: vaultID
            )
        }
    }

    @Test func contentKeyWrapRoundTripsAndRejectsObjectSwap() throws {
        let vaultID = VaultIdentifier()
        let rootKey = try VaultKeyMaterial.random()
        let contentKey = try VaultKeyMaterial.random()
        let objectToken = try VaultCryptography.makeObjectToken()
        let otherToken = try VaultCryptography.makeObjectToken()

        let wrapped = try VaultCryptography.wrapContentKey(
            contentKey,
            objectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID
        )
        let unwrapped = try VaultCryptography.unwrapContentKey(
            wrapped,
            objectToken: objectToken,
            rootKey: rootKey,
            vaultID: vaultID
        )
        #expect(unwrapped == contentKey)

        #expect(throws: VaultCryptoError.authenticationFailed) {
            try VaultCryptography.unwrapContentKey(
                wrapped,
                objectToken: otherToken,
                rootKey: rootKey,
                vaultID: vaultID
            )
        }
    }

    @Test func bootstrapUnlockRequiresRecoverySecretAndVaultIdentity() throws {
        let vaultID = VaultIdentifier()
        let rootKey = try VaultKeyMaterial.random()
        let recoverySecret = try VaultKeyMaterial.random()
        let bootstrap = try VaultBootstrap.create(
            vaultID: vaultID,
            rootKey: rootKey,
            recoverySecret: recoverySecret
        )

        let unlocked = try VaultBootstrap.unlock(
            bootstrap,
            recoverySecret: recoverySecret,
            expectedVaultID: vaultID
        )
        #expect(unlocked.vaultID == vaultID)
        #expect(unlocked.rootKey == rootKey)
        #expect(unlocked.keyEpoch == VaultFormat.currentKeyEpoch)

        #expect(throws: VaultCryptoError.authenticationFailed) {
            try VaultBootstrap.unlock(
                bootstrap,
                recoverySecret: VaultKeyMaterial(data: Data(repeating: 0xAA, count: 32))!,
                expectedVaultID: vaultID
            )
        }
        #expect(throws: VaultCryptoError.unexpectedVault) {
            try VaultBootstrap.unlock(
                bootstrap,
                recoverySecret: recoverySecret,
                expectedVaultID: VaultIdentifier()
            )
        }
    }

    @Test func recoveryKitRoundTripsAndDetectsTypingError() throws {
        let kit = VaultRecoveryKit(
            vaultID: VaultIdentifier(
                rawValue: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
            ),
            driveID: 123,
            vaultRootFileID: 456,
            vaultHeaderFileID: 789,
            recoverySecret: VaultKeyMaterial(data: Data(0..<32))!
        )

        let decoded = try VaultRecoveryKit(encoded: kit.encoded.lowercased())
        #expect(decoded == kit)
        #expect(kit.encoded.hasPrefix("KPV1-"))

        var mistyped = kit.encoded
        let index = mistyped.index(before: mistyped.endIndex)
        mistyped.replaceSubrange(index...index, with: mistyped[index] == "A" ? "B" : "A")
        let detectsTypingError: Bool = {
            do {
                _ = try VaultRecoveryKit(encoded: mistyped)
                return false
            } catch VaultCryptoError.recoveryKitChecksumMismatch {
                return true
            } catch VaultCryptoError.recoveryKitInvalid {
                return true
            } catch {
                return false
            }
        }()
        #expect(detectsTypingError)
    }

    @Test(
        arguments: [
            Data(),
            Data("hello".utf8),
            Data(repeating: 0x5A, count: 5_000),
            Data(repeating: 0xC3, count: VaultFormat.contentFrameSize + 123),
        ]
    )
    func contentCipherRoundTripsAcrossPaddingAndFrameBoundaries(plaintext: Data) throws {
        try withTemporaryDirectory { directory in
            let plaintextURL = directory.appendingPathComponent("plain")
            let encryptedURL = directory.appendingPathComponent("cipher")
            let decryptedURL = directory.appendingPathComponent("opened")
            try plaintext.write(to: plaintextURL)
            let context = try contentContext()

            let result = try VaultContentCipher.encrypt(
                plaintextURL: plaintextURL,
                ciphertextURL: encryptedURL,
                context: context
            )
            #expect(result.plaintextLength == plaintext.count)
            #expect(result.plaintextDigest == Data(SHA256.hash(data: plaintext)))
            #expect((try Data(contentsOf: encryptedURL)).range(of: plaintext) == nil)

            try VaultContentCipher.decrypt(
                ciphertextURL: encryptedURL,
                plaintextURL: decryptedURL,
                context: context,
                contentKey: result.contentKey,
                expectedNoncePrefix: result.noncePrefix,
                expectedPlaintextLength: result.plaintextLength,
                expectedPlaintextDigest: result.plaintextDigest,
                expectedFrameCount: result.frameCount
            )
            #expect(try Data(contentsOf: decryptedURL) == plaintext)
        }
    }

    @Test func contentCipherRandomizesIdenticalPlaintextAndRejectsTampering() throws {
        try withTemporaryDirectory { directory in
            let plaintext = Data(repeating: 0x7E, count: 12_345)
            let plaintextURL = directory.appendingPathComponent("plain")
            let firstURL = directory.appendingPathComponent("first")
            let secondURL = directory.appendingPathComponent("second")
            let openedURL = directory.appendingPathComponent("opened")
            try plaintext.write(to: plaintextURL)
            let firstContext = try contentContext()
            let secondContext = try contentContext()

            let first = try VaultContentCipher.encrypt(
                plaintextURL: plaintextURL,
                ciphertextURL: firstURL,
                context: firstContext
            )
            _ = try VaultContentCipher.encrypt(
                plaintextURL: plaintextURL,
                ciphertextURL: secondURL,
                context: secondContext
            )
            #expect(try Data(contentsOf: firstURL) != Data(contentsOf: secondURL))

            var tampered = try Data(contentsOf: firstURL)
            tampered[tampered.index(before: tampered.endIndex)] ^= 0x80
            try tampered.write(to: firstURL)
            let rejectedTamperingWithoutPartialPlaintext: Bool = {
                do {
                    try VaultContentCipher.decrypt(
                        ciphertextURL: firstURL,
                        plaintextURL: openedURL,
                        context: firstContext,
                        contentKey: first.contentKey,
                        expectedNoncePrefix: first.noncePrefix,
                        expectedPlaintextLength: first.plaintextLength,
                        expectedPlaintextDigest: first.plaintextDigest,
                        expectedFrameCount: first.frameCount
                    )
                    return false
                } catch VaultCryptoError.authenticationFailed {
                    return FileManager.default.fileExists(atPath: openedURL.path) == false
                } catch {
                    return false
                }
            }()
            #expect(rejectedTamperingWithoutPartialPlaintext)
        }
    }

    @Test func cancelledContentDecryptionRemovesPartialPlaintext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCryptographyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let plaintextURL = directory.appendingPathComponent("plain")
        let encryptedURL = directory.appendingPathComponent("cipher")
        let openedURL = directory.appendingPathComponent("opened")
        try Data(repeating: 0x4D, count: VaultFormat.contentFrameSize * 2 + 1)
            .write(to: plaintextURL)
        let context = try contentContext()
        let result = try VaultContentCipher.encrypt(
            plaintextURL: plaintextURL,
            ciphertextURL: encryptedURL,
            context: context
        )

        let task = Task {
            await Task.yield()
            try VaultContentCipher.decrypt(
                ciphertextURL: encryptedURL,
                plaintextURL: openedURL,
                context: context,
                contentKey: result.contentKey,
                expectedNoncePrefix: result.noncePrefix,
                expectedPlaintextLength: result.plaintextLength,
                expectedPlaintextDigest: result.plaintextDigest,
                expectedFrameCount: result.frameCount
            )
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(FileManager.default.fileExists(atPath: openedURL.path) == false)
    }

    @Test func finalFramePaddingUsesDocumentedBuckets() {
        #expect(VaultContentCipher.paddedFinalFrameSize(for: 0) == 4_096)
        #expect(VaultContentCipher.paddedFinalFrameSize(for: 4_096) == 4_096)
        #expect(VaultContentCipher.paddedFinalFrameSize(for: 4_097) == 8_192)
        #expect(VaultContentCipher.paddedFinalFrameSize(for: 600_000) == 1_048_576)
        #expect(
            VaultContentCipher.paddedFinalFrameSize(for: VaultFormat.contentFrameSize)
                == VaultFormat.contentFrameSize
        )
    }

    @Test func inMemoryKeyStoreKeepsRootAndTrustedFrontierSeparate() async throws {
        let store = InMemoryVaultKeyStore()
        let vaultID = VaultIdentifier()
        let key = try VaultKeyMaterial.random()
        let state = VaultTrustedState(
            vaultID: vaultID,
            keyEpoch: 2,
            frontier: VaultFrontier(transactionIDs: [UUID()]),
            checkpointDigest: Data(repeating: 0x20, count: 32)
        )

        try await store.saveRootKey(key, vaultID: vaultID)
        try await store.saveTrustedState(state)
        #expect(try await store.loadRootKey(vaultID: vaultID) == key)
        #expect(try await store.loadTrustedState(vaultID: vaultID) == state)

        try await store.deleteRootKey(vaultID: vaultID)
        #expect(try await store.loadRootKey(vaultID: vaultID) == nil)
        #expect(try await store.loadTrustedState(vaultID: vaultID) == state)
    }

    private func contentContext() throws -> VaultContentEncryptionContext {
        VaultContentEncryptionContext(
            vaultID: VaultIdentifier(),
            itemID: VaultItemIdentifier(),
            contentRevision: try VaultRevision.random(),
            objectToken: try VaultCryptography.makeObjectToken()
        )
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultCryptographyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private struct Fixture: Codable, Equatable {
    let message: String
    let count: Int
}
