#if os(macOS) && STABILITY
import Darwin
import Foundation

enum FinderStabilityCommandLine {
    nonisolated static let commandFlag = "--finder-stability"

    nonisolated static func shouldHandle(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(commandFlag)
    }

    static func runInCurrentProcess(arguments: [String]) -> Int32 {
        var exitCode: Int32?
        Task { @MainActor in
            exitCode = await run(arguments: arguments)
        }
        while exitCode == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        return exitCode ?? 1
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        await run(
            arguments: arguments,
            executor: SystemFinderStabilityCommandExecutor()
        )
    }

    @MainActor
    static func run(
        arguments: [String],
        executor: any FinderStabilityCommandExecuting
    ) async -> Int32 {
        do {
            switch try FinderStabilityArgumentParser.parse(arguments: arguments) {
            case .notRequested:
                return 0
            case .help:
                print(usage)
                return 0
            case .execute(let options):
                let result: FinderStabilityCommandResult
                switch options.mode {
                case .preflight:
                    result = await executor.preflight(
                        requestPermissions: options.requestPermissions
                    )
                case .run:
                    result = await executor.run(
                        requestPermissions: options.requestPermissions
                    )
                case .recover:
                    result = await executor.recoverStaleRun()
                }
                print(result.safeConsoleDescription)
                return result.exitCode
            }
        } catch let error as FinderStabilityArgumentError {
            fputs("finder stability command rejected: \(error.safeDescription)\n", stderr)
            return 2
        } catch {
            fputs("finder stability command failed safely\n", stderr)
            return 1
        }
    }

    nonisolated static var usage: String {
        """
        Usage:
          potassiumProvider --finder-stability preflight [--request-permissions]
          potassiumProvider --finder-stability run --yes-live [--request-permissions]
          potassiumProvider --finder-stability recover --yes-recover

        Options:
          preflight              Verify the Stability build, lab, File Provider domain, and macOS consent without Finder or remote mutation.
          run                    Execute the verified, lab-scoped Finder scenario sequence and seal its evidence bundle.
          recover                Preserve and abandon evidence owned by a Finder runner process that is no longer alive.
          --yes-live             Required for run. Confirms use of the saved development account and disposable lab root.
          --yes-recover          Required for recover. Performs local evidence lifecycle recovery only.
          --request-permissions  Ask macOS to present Accessibility and Finder Automation consent prompts when needed.
        """
    }
}

enum FinderStabilityCommandMode: String, Equatable, Sendable {
    case preflight
    case run
    case recover
}

struct FinderStabilityCommandOptions: Equatable, Sendable {
    let mode: FinderStabilityCommandMode
    let requestPermissions: Bool
}

enum FinderStabilityArgumentParseResult: Equatable, Sendable {
    case notRequested
    case help
    case execute(FinderStabilityCommandOptions)
}

enum FinderStabilityArgumentError: Error, Equatable, Sendable {
    case missingMode
    case duplicateMode
    case liveConfirmationRequired
    case liveConfirmationNotAllowedForPreflight
    case liveConfirmationNotAllowedForRecovery
    case recoveryConfirmationRequired
    case recoveryConfirmationNotAllowed
    case permissionRequestNotAllowedForRecovery
    case unknownOption

    var safeDescription: String {
        switch self {
        case .missingMode:
            "choose preflight or run"
        case .duplicateMode:
            "choose exactly one mode"
        case .liveConfirmationRequired:
            "run requires --yes-live"
        case .liveConfirmationNotAllowedForPreflight:
            "--yes-live is accepted only with run"
        case .liveConfirmationNotAllowedForRecovery:
            "--yes-live is not accepted with recover"
        case .recoveryConfirmationRequired:
            "recover requires --yes-recover"
        case .recoveryConfirmationNotAllowed:
            "--yes-recover is accepted only with recover"
        case .permissionRequestNotAllowedForRecovery:
            "--request-permissions is not accepted with recover"
        case .unknownOption:
            "unknown option"
        }
    }
}

enum FinderStabilityArgumentParser {
    nonisolated static func parse(arguments: [String]) throws -> FinderStabilityArgumentParseResult {
        guard let flagIndex = arguments.dropFirst().firstIndex(of: FinderStabilityCommandLine.commandFlag) else {
            return .notRequested
        }
        let commandArguments = arguments[arguments.index(after: flagIndex)...]
        if commandArguments.contains("--help") || commandArguments.contains("-h") {
            return .help
        }

        var mode: FinderStabilityCommandMode?
        var requestPermissions = false
        var confirmedLiveRun = false
        var confirmedRecovery = false
        for argument in commandArguments {
            switch argument {
            case FinderStabilityCommandMode.preflight.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .preflight
            case FinderStabilityCommandMode.run.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .run
            case FinderStabilityCommandMode.recover.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .recover
            case "--request-permissions":
                requestPermissions = true
            case "--yes-live":
                confirmedLiveRun = true
            case "--yes-recover":
                confirmedRecovery = true
            default:
                throw FinderStabilityArgumentError.unknownOption
            }
        }

        guard let mode else { throw FinderStabilityArgumentError.missingMode }
        switch mode {
        case .preflight where confirmedLiveRun:
            throw FinderStabilityArgumentError.liveConfirmationNotAllowedForPreflight
        case .preflight where confirmedRecovery:
            throw FinderStabilityArgumentError.recoveryConfirmationNotAllowed
        case .run where confirmedLiveRun == false:
            throw FinderStabilityArgumentError.liveConfirmationRequired
        case .run where confirmedRecovery:
            throw FinderStabilityArgumentError.recoveryConfirmationNotAllowed
        case .recover where confirmedRecovery == false:
            throw FinderStabilityArgumentError.recoveryConfirmationRequired
        case .recover where confirmedLiveRun:
            throw FinderStabilityArgumentError.liveConfirmationNotAllowedForRecovery
        case .recover where requestPermissions:
            throw FinderStabilityArgumentError.permissionRequestNotAllowedForRecovery
        default:
            break
        }
        return .execute(FinderStabilityCommandOptions(
            mode: mode,
            requestPermissions: requestPermissions
        ))
    }
}

enum FinderStabilityCommandResult: Equatable, Sendable {
    case ready
    case completed
    case recovered
    case checkpoint
    case rejected
    case failed

    var exitCode: Int32 {
        switch self {
        case .ready, .completed, .recovered:
            0
        case .checkpoint:
            3
        case .rejected:
            2
        case .failed:
            1
        }
    }

    var safeConsoleDescription: String {
        switch self {
        case .ready:
            "finder stability preflight: ready"
        case .completed:
            "finder stability run: evidence bundle sealed"
        case .recovered:
            "finder stability recovery: stale run preserved and released"
        case .checkpoint:
            "finder stability checkpoint: macOS consent or variable Finder UI requires operator action"
        case .rejected:
            "finder stability rejected: lab or domain safety evidence did not pass"
        case .failed:
            "finder stability failed: inspect the redacted Stability evidence bundle"
        }
    }
}

@MainActor
protocol FinderStabilityCommandExecuting {
    func preflight(requestPermissions: Bool) async -> FinderStabilityCommandResult
    func run(requestPermissions: Bool) async -> FinderStabilityCommandResult
    func recoverStaleRun() async -> FinderStabilityCommandResult
}
#endif
