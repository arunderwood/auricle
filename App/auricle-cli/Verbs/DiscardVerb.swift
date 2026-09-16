import ArgumentParser

struct DiscardVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discard",
        abstract: "Delete cached audio and state for a captured-but-unwanted meeting."
    )

    @Argument(help: "Meeting ID.")
    var id: String

    @Flag(help: "Suppress stdout output; exit code only.")
    var quiet = false

    func run() async throws {
        try notYetImplemented("discard")
    }
}
