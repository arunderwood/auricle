import ArgumentParser
import Orchestrator

struct AttributeVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attribute",
        abstract: "Attribute speakers for a meeting. Opens the GUI by default.",
    )

    @OptionGroup var arguments: AttributeArguments

    func run() async throws {
        try notYetImplemented("attribute")
    }
}
