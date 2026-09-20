import ArgumentParser
import Orchestrator

struct KeepVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keep",
        abstract: "Confirm a meeting note has been reviewed and arm its retention timer.",
    )

    @OptionGroup var arguments: KeepArguments

    func run() async throws {
        try notYetImplemented("keep")
    }
}
