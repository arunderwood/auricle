import ArgumentParser
import Orchestrator

struct StatusVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show a meeting's state, artifact paths, and retention status.",
    )

    @OptionGroup var arguments: StatusArguments

    func run() async throws {
        try notYetImplemented("status")
    }
}
