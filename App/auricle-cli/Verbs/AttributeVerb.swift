import ArgumentParser

struct AttributeVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attribute",
        abstract: "Attribute speakers for a meeting. Opens the GUI by default.",
    )

    @Argument(help: "Meeting ID.")
    var id: String

    @Flag(help: "Apply the last-known speaker mapping instead of opening the GUI.")
    var batch = false

    func run() async throws {
        try notYetImplemented("attribute")
    }
}
