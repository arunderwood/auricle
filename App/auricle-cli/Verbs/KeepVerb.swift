import ArgumentParser

struct KeepVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep",
        abstract: "Confirm a meeting note has been reviewed and arm its retention timer."
    )

    @Argument(help: "Meeting ID.")
    var id: String

    @Flag(help: "Suppress stdout output; exit code only.")
    var quiet = false

    func run() async throws {
        try notYetImplemented("keep")
    }
}
