import ArgumentParser
import Orchestrator

struct RecordVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Start capture.",
    )

    @OptionGroup var arguments: RecordArguments

    func run() async throws {
        try notYetImplemented("record")
    }
}
