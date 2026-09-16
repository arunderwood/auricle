import ArgumentParser

// The one grouped verb (Decision 1.5): every other verb is flat, but reading
// vs. writing a config value are different enough operations to warrant
// their own subcommands rather than a single verb branching on flags.
struct ConfigVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Read or write configuration values.",
        subcommands: [Get.self, Set.self]
    )

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "get",
            abstract: "Read a config value, or all values (secrets redacted) if <key> is omitted."
        )

        @Argument(help: "Config key.")
        var key: String?

        func run() async throws {
            try notYetImplemented("config get")
        }
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Write a config value."
        )

        @Argument(help: "Config key.")
        var key: String

        @Argument(help: "Value to write.")
        var value: String

        func run() async throws {
            try notYetImplemented("config set")
        }
    }
}
