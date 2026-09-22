import ArgumentParser
import Core
import Orchestrator

/// The one grouped verb (Decision 1.5): every other verb is flat, but reading
/// vs. writing a config value are different enough operations to warrant
/// their own subcommands rather than a single verb branching on flags.
struct ConfigVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or write configuration values.",
        subcommands: [Get.self, Set.self],
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Read a config value, or all values (secrets redacted) if <key> is omitted.",
        )

        @OptionGroup var arguments: ConfigGetArguments

        func run() async throws {
            try notYetImplemented("config get")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Write a config value.",
        )

        @OptionGroup var arguments: ConfigSetArguments

        func run() async throws {
            do {
                try ConfigWriter.set(arguments.key, to: arguments.value)
            } catch let error as ConfigWriter.WriterError {
                throw failure(error.message)
            } catch {
                throw failure("could not write the config (\(String(describing: error))).")
            }
        }

        private func failure(_ message: String) -> ExitCode {
            writeStderr("config set: \(message)")
            return ExitCode(1)
        }
    }
}
