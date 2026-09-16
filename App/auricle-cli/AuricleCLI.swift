import ArgumentParser

@main
struct AuricleCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auricle",
        abstract: "Personal meeting notes pipeline"
    )
}
