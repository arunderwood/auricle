import ArgumentParser
import Orchestrator

struct DiscardVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discard",
        abstract: "Delete cached audio and state for a captured-but-unwanted meeting.",
    )

    @OptionGroup var arguments: DiscardArguments

    func run() async throws {
        try notYetImplemented("discard")
    }
}
