import ArgumentParser

struct ListVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings auricle on this Mac knows about."
    )

    @Flag(help: "Include verified and discarded meetings.")
    var all = false

    @Flag(help: "Output machine-readable JSON.")
    var json = false

    func run() async throws {
        try notYetImplemented("list")
    }
}
