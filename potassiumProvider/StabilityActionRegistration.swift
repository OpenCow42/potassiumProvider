#if os(macOS) && STABILITY
import Foundation

enum StabilityActionRegistrationError: Error {
    case unavailable, ambiguous, timedOut
}

/// Actions extensions are discovered separately from the replicated instance.
/// Attesting the latter does not exclude an older Actions binary with the same ID.
@MainActor
enum StabilityActionRegistration {
    static func verify(appURL: URL) async throws {
        try StabilityAppGroupProvisioning.verify(appURL: appURL)
        let extensionURL = appURL.appendingPathComponent("Contents/PlugIns/potassiumProviderActions.appex")
        guard let identifier = Bundle(url: extensionURL)?.bundleIdentifier else { throw StabilityActionRegistrationError.unavailable }
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("stability-registration-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw StabilityActionRegistrationError.unavailable
        }
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-A", "-D", "-v", "-i", identifier]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw StabilityActionRegistrationError.timedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationStatus == 0,
              (try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_024 * 1_024,
              let listing = String(data: try Data(contentsOf: outputURL), encoding: .utf8) else {
            throw StabilityActionRegistrationError.unavailable
        }
        do { try validate(listing: listing, identifier: identifier, expectedURL: extensionURL) }
        catch {
            print("finder stability preflight: Actions extension registration is missing or ambiguous; register only the selected app's Actions extension before retrying")
            throw error
        }
    }

    static func validate(listing: String, identifier: String, expectedURL: URL) throws {
        let registrations = listing.split(separator: "\n").filter { $0.contains(identifier + "(") }
        guard registrations.count == 1, let line = registrations.first else { throw StabilityActionRegistrationError.ambiguous }
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 4, let path = columns.last, path.hasPrefix("/"),
              URL(fileURLWithPath: String(path)).standardizedFileURL.resolvingSymlinksInPath() ==
                expectedURL.standardizedFileURL.resolvingSymlinksInPath() else { throw StabilityActionRegistrationError.ambiguous }
    }
}
#endif
