import ArgumentParser

struct StopVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop active capture."
    )

    @Flag(help: "Suppress stdout output; exit code only.")
    var quiet = false

    func run() async throws {
        try notYetImplemented("stop")
    }
}
