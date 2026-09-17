import ArgumentParser

struct RecordVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start capture.",
    )

    @Argument(help: "Meeting ID to use. A new one is generated if omitted.")
    var id: String?

    @Flag(help: "Reuse <id> even if captured audio already exists for it.")
    var replace = false

    @Flag(help: "Suppress stdout output; exit code only.")
    var quiet = false

    func run() async throws {
        try notYetImplemented("record")
    }
}
