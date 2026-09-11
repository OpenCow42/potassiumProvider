#if os(macOS) && STABILITY
import Darwin
import AppKit
import Foundation
import PotassiumProviderCore

enum FinderStabilityCommandLine {
    nonisolated static let commandFlag = "--finder-stability"

    nonisolated static func shouldHandle(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(commandFlag)
    }

    static func runInCurrentProcess(arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        var exitCode: Int32?
        Task { @MainActor in
            exitCode = await run(arguments: arguments)
            application.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                application.postEvent(wake, atStart: true)
            }
        }
        // NSApplication dispatches panel and permission events while Swift
        // concurrency drives the suite. A bare CFRunLoop cannot operate sheets.
        application.run()
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
                    result = await executor.run(requestPermissions: options.requestPermissions,
                        extensionLaunchMode: options.extensionLaunchMode,
                        includePermanentDeletion: options.includePermanentDeletion)
                case .conflicts:
                    result = await executor.conflicts(requestPermissions: options.requestPermissions, selectedCase: options.conflictCase, extensionLaunchMode: options.extensionLaunchMode)
                case .recover:
                    result = await executor.recoverStaleRun()
                case .provision:
                    result = await executor.provision()
                case .watch:
                    result = await executor.watch()
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
          potassiumProvider --finder-stability provision --yes-live
          potassiumProvider --finder-stability watch
          potassiumProvider --finder-stability preflight [--request-permissions]
          potassiumProvider --finder-stability run --yes-live [--include-permanent-deletion] [--extension-state fresh|running] [--request-permissions]
          potassiumProvider --finder-stability conflicts --yes-live [--case CASE] [--extension-state fresh|running] [--request-permissions]
          potassiumProvider --finder-stability recover --yes-recover

        Options:
          preflight              Verify the Stability build, lab, File Provider domain, and macOS consent without Finder or remote mutation.
          run                    Execute the verified, lab-scoped Finder scenario sequence and seal its evidence bundle.
          recover                Preserve and abandon evidence owned by a Finder runner process that is no longer alive.
          --yes-live             Required for run, provision, or conflicts. Confirms use of the saved development account and disposable lab root.
          --yes-recover          Required for recover. Performs local evidence lifecycle recovery only.
          --request-permissions  Ask macOS to present Accessibility, screen recording, and Finder Automation consent prompts when needed.
          --include-permanent-deletion  Include scenario 12 and its exact-item confirmation. Default: defer deletion and continue scenarios 13–16; exit 4 if all selected scenarios pass.
        """
    }
}

enum FinderStabilityCommandMode: String, Equatable, Sendable {
    case preflight
    case run
    case recover
    case provision
    case watch
    case conflicts
}

struct FinderStabilityCommandOptions: Equatable, Sendable {
    let mode: FinderStabilityCommandMode
    let requestPermissions: Bool
    var conflictCase: StabilityLiveConflictCase? = nil
    var extensionLaunchMode: StabilityExtensionLaunchMode? = nil
    var includePermanentDeletion = false
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
            "choose preflight, run, conflicts, provision, watch, or recover"
        case .duplicateMode:
            "choose exactly one mode"
        case .liveConfirmationRequired:
            "run, provision, and conflicts require --yes-live"
        case .liveConfirmationNotAllowedForPreflight:
            "--yes-live is accepted only with run, provision, or conflicts"
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
        var conflictCase: StabilityLiveConflictCase?
        var expectsCase = false
        var extensionLaunchMode: StabilityExtensionLaunchMode?
        var expectsLaunchMode = false
        var includePermanentDeletion = false
        for argument in commandArguments {
            if expectsLaunchMode {
                guard let value = StabilityExtensionLaunchMode(rawValue: argument), extensionLaunchMode == nil else { throw FinderStabilityArgumentError.unknownOption }
                extensionLaunchMode = value; expectsLaunchMode = false; continue
            }
            if expectsCase {
                guard let value = StabilityLiveConflictCase(rawValue: argument), conflictCase == nil else { throw FinderStabilityArgumentError.unknownOption }
                conflictCase = value; expectsCase = false; continue
            }
            switch argument {
            case FinderStabilityCommandMode.provision.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .provision
            case FinderStabilityCommandMode.watch.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .watch
            case FinderStabilityCommandMode.preflight.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .preflight
            case FinderStabilityCommandMode.run.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .run
            case FinderStabilityCommandMode.recover.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .recover
            case "--extension-state":
                expectsLaunchMode = true
            case "--case":
                expectsCase = true
            case FinderStabilityCommandMode.conflicts.rawValue:
                guard mode == nil else { throw FinderStabilityArgumentError.duplicateMode }
                mode = .conflicts
            case "--request-permissions":
                requestPermissions = true
            case "--yes-live":
                confirmedLiveRun = true
            case "--yes-recover":
                confirmedRecovery = true
            case "--include-permanent-deletion":
                guard !includePermanentDeletion else { throw FinderStabilityArgumentError.unknownOption }
                includePermanentDeletion = true
            default:
                throw FinderStabilityArgumentError.unknownOption
            }
        }

        guard let mode else { throw FinderStabilityArgumentError.missingMode }
        guard !expectsCase, !expectsLaunchMode,
              !includePermanentDeletion || mode == .run,
              conflictCase == nil || mode == .conflicts,
              extensionLaunchMode == nil || mode == .conflicts || mode == .run else { throw FinderStabilityArgumentError.unknownOption }
        switch mode {
        case .conflicts where !confirmedLiveRun:
            throw FinderStabilityArgumentError.liveConfirmationRequired
        case .conflicts where confirmedRecovery:
            throw FinderStabilityArgumentError.recoveryConfirmationNotAllowed
        case .watch where confirmedLiveRun || confirmedRecovery || requestPermissions:
            throw FinderStabilityArgumentError.unknownOption
        case .provision where confirmedRecovery || requestPermissions:
            throw FinderStabilityArgumentError.unknownOption
        case .preflight where confirmedLiveRun:
            throw FinderStabilityArgumentError.liveConfirmationNotAllowedForPreflight
        case .preflight where confirmedRecovery:
            throw FinderStabilityArgumentError.recoveryConfirmationNotAllowed
        case .run where confirmedLiveRun == false, .provision where confirmedLiveRun == false:
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
            requestPermissions: requestPermissions, conflictCase: conflictCase, extensionLaunchMode: extensionLaunchMode,
            includePermanentDeletion: includePermanentDeletion
        ))
    }
}

enum FinderStabilityCommandResult: Equatable, Sendable {
    case ready
    case completed
    case completedWithDeferredDeletion
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
        case .completedWithDeferredDeletion:
            4
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
        case .completedWithDeferredDeletion:
            "finder stability run: 15 scenarios passed; permanent deletion deferred; evidence bundle sealed; full acceptance incomplete"
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
    func run(requestPermissions: Bool, extensionLaunchMode: StabilityExtensionLaunchMode?) async -> FinderStabilityCommandResult
    func run(requestPermissions: Bool, extensionLaunchMode: StabilityExtensionLaunchMode?, includePermanentDeletion: Bool) async -> FinderStabilityCommandResult
    func conflicts(requestPermissions: Bool, selectedCase: StabilityLiveConflictCase?, extensionLaunchMode: StabilityExtensionLaunchMode?) async -> FinderStabilityCommandResult
    func recoverStaleRun() async -> FinderStabilityCommandResult
    func provision() async -> FinderStabilityCommandResult
    func watch() async -> FinderStabilityCommandResult
}
extension FinderStabilityCommandExecuting {
    func run(requestPermissions: Bool, extensionLaunchMode: StabilityExtensionLaunchMode?, includePermanentDeletion: Bool) async -> FinderStabilityCommandResult {
        // Older injected executors cannot silently ignore explicit deletion selection.
        guard !includePermanentDeletion else { return .rejected }
        return await run(requestPermissions: requestPermissions, extensionLaunchMode: extensionLaunchMode)
    }
    func run(requestPermissions: Bool, extensionLaunchMode: StabilityExtensionLaunchMode?) async -> FinderStabilityCommandResult {
        guard extensionLaunchMode == nil else { return .rejected }
        return await run(requestPermissions: requestPermissions)
    }
    func conflicts(requestPermissions: Bool, selectedCase: StabilityLiveConflictCase?, extensionLaunchMode: StabilityExtensionLaunchMode?) async -> FinderStabilityCommandResult { .rejected }
    func provision() async -> FinderStabilityCommandResult { .rejected }
    func watch() async -> FinderStabilityCommandResult { .rejected }
}
#endif
