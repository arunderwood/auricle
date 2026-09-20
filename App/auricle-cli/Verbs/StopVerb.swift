import ArgumentParser
import Orchestrator

struct StopVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop active capture.",
    )

    @OptionGroup var arguments: StopArguments

    func run() async throws {
        try notYetImplemented("stop")
    }
}
