import ArgumentParser
import Orchestrator

struct RunVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the pipeline forward from a meeting's current state.",
    )

    @OptionGroup var arguments: RunArguments

    func run() async throws {
        try notYetImplemented("run")
    }
}
