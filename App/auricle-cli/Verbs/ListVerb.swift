import ArgumentParser
import Orchestrator

struct ListVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings auricle on this Mac knows about.",
    )

    @OptionGroup var arguments: ListArguments

    func run() async throws {
        try notYetImplemented("list")
    }
}
