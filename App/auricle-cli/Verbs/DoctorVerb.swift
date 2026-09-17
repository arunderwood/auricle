import ArgumentParser

struct DoctorVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose permission, Gatekeeper-trust, and vault-path problems.",
    )

    func run() async throws {
        try notYetImplemented("doctor")
    }
}
