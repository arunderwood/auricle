import ArgumentParser

struct StatusVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show a meeting's state, artifact paths, and retention status.",
    )

    @Argument(help: "Meeting ID.")
    var id: String

    @Flag(help: "Output machine-readable JSON.")
    var json = false

    func run() async throws {
        try notYetImplemented("status")
    }
}
