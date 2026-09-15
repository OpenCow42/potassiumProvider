import FileProvider
import Foundation
import Testing
@testable import PotassiumProviderCore

@Suite("Action selection identity")
struct ProviderActionItemResolverTests {
    private let url = URL(fileURLWithPath: "/tmp/generated-action.txt")

    private func resolver(item: String = "42", domain: String = "expected") -> ProviderActionItemResolver {
        let url = url
        return .init(visibleURL: { input, completion in
            #expect(input == "__fp/fs/docID(123)" || input == "42")
            completion(.success(url))
        }, identifier: { resolvedURL, completion in
            #expect(resolvedURL == url)
            completion(.success(.init(itemIdentifier: item, domainIdentifier: domain)))
        })
    }

    @Test(arguments: ["__fp/fs/docID(123)", "42"])
    func resolvesBothOpaqueAndCanonicalSelectionsThroughExpectedDomain(_ selection: String) async throws {
        #expect(try await resolver().resolve(selection, domainIdentifier: "expected", engine: .legacyPlaintext) == "42")
    }

    @Test func rejectsCrossDomainSelectionEvenWhenNumericIDMatches() async {
        await #expect(throws: ProviderActionItemResolutionError.domainMismatch) {
            try await resolver(domain: "different").resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext)
        }
    }

    @Test(arguments: ["__fp/fs/docID(123)", "", "NSFileProviderTrashContainerItemIdentifier", "NSFileProviderWorkingSetContainerItemIdentifier"])
    func unresolvedAndVirtualContainerResultsCannotLoadActions(_ item: String) async {
        await #expect(throws: ProviderActionItemResolutionError.invalidIdentifier) {
            try await resolver(item: item).resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext)
        }
    }

    @Test func rejectsSameDomainReplacementOfACanonicalSelection() async {
        await #expect(throws: ProviderActionItemResolutionError.invalidIdentifier) {
            try await resolver(item: "43").resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext)
        }
    }

    @Test func enginesStayIsolatedAndVaultIdentifiersRemainStable() async throws {
        let vault = VaultItemIdentifier().fileProviderIdentifier
        #expect(try await resolver(item: vault).resolve("__fp/fs/docID(123)", domainIdentifier: "expected", engine: .opaqueVaultV2) == vault)
        #expect(throws: ProviderActionItemResolutionError.invalidIdentifier) {
            try ProviderActionItemResolver.validate(vault, engine: .legacyPlaintext)
        }
        #expect(throws: ProviderActionItemResolutionError.invalidIdentifier) {
            try ProviderActionItemResolver.validate("42", engine: .opaqueVaultV2)
        }
        #expect(throws: ProviderActionItemResolutionError.invalidIdentifier) {
            try ProviderActionItemResolver.validate(vault, engine: .opaqueVaultV1)
        }
        #expect(try ProviderActionItemResolver.validate("42", engine: .legacyPlaintext) == "42")
    }

    @Test func failuresDoNotExposeSystemPathsOrIdentifiersOrPerformReverseLookup() async {
        let resolver = ProviderActionItemResolver(visibleURL: { _, completion in
            completion(.failure(NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "private path"])))
        }, identifier: { _, _ in Issue.record("Reverse lookup must not run after failure") })
        await #expect(throws: ProviderActionItemResolutionError.unavailable) {
            try await resolver.resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext)
        }
        #expect(!ProviderActionItemResolutionError.unavailable.localizedDescription.contains("private path"))
    }

    @Test func rejectsNonFileURLs() async {
        let resolver = ProviderActionItemResolver(visibleURL: { _, completion in
            completion(.success(URL(string: "https://example.invalid")!))
        }, identifier: { _, _ in Issue.record("Non-file URLs must not be resolved") })
        await #expect(throws: ProviderActionItemResolutionError.unavailable) {
            try await resolver.resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext)
        }
    }

    @Test func boundsMissingSystemCallback() async {
        let resolver = ProviderActionItemResolver(visibleURL: { _, _ in }, identifier: { _, _ in Issue.record("Must not resolve after timeout") })
        await #expect(throws: ProviderActionItemResolutionError.timedOut) {
            try await resolver.resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext, timeout: .milliseconds(10))
        }
    }

    @Test func cancellationDuringReverseLookupIgnoresLateCompletion() async throws {
        let registered = AsyncStream<ProviderActionItemResolver.Completion<ProviderActionItemResolver.Binding>>.makeStream()
        let url = url
        let resolver = ProviderActionItemResolver(visibleURL: { _, completion in completion(.success(url)) }, identifier: { _, completion in
            registered.continuation.yield(completion)
        })
        let task = Task { try await resolver.resolve("42", domainIdentifier: "expected", engine: .legacyPlaintext) }
        var iterator = registered.stream.makeAsyncIterator()
        let completion = try #require(await iterator.next())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        completion(.success(.init(itemIdentifier: "42", domainIdentifier: "expected")))
        registered.continuation.finish()
    }
}
