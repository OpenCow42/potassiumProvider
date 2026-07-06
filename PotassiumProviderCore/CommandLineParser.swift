import Foundation

/// A small dependency-free parser for internal development command modes.
public struct CommandLineParser: Sendable {
    public init() {}

    public func requestsHelp(_ arguments: [String]) -> Bool {
        arguments.contains("--help") || arguments.contains("-h")
    }

    public func arguments(after flag: String, in arguments: [String]) -> [String]? {
        guard let flagIndex = arguments.firstIndex(of: flag) else {
            return nil
        }

        return Array(arguments[arguments.index(after: flagIndex)...])
    }

    public func flags(in arguments: [String], allowedFlags: Set<String>) throws -> Set<String> {
        var parsedFlags: Set<String> = []

        for argument in arguments {
            guard argument.hasPrefix("-") else {
                throw CommandLineError.unexpectedArgument(argument)
            }

            guard allowedFlags.contains(argument) else {
                throw CommandLineError.unknownOption(argument)
            }

            parsedFlags.insert(argument)
        }

        return parsedFlags
    }
}

public enum CommandLineError: Error, Equatable, LocalizedError, Sendable {
    case unknownOption(String)
    case unexpectedArgument(String)

    public var errorDescription: String? {
        switch self {
        case .unknownOption(let option):
            "Unknown command-line option: \(option)"
        case .unexpectedArgument(let argument):
            "Unexpected command-line argument: \(argument)"
        }
    }
}
