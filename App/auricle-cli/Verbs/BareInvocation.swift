import ArgumentParser
import Core
import State

// `swift-argument-parser`'s `defaultSubcommand` fallback only fires for a
// command already present in the tree (`CommandParser` looks it up as a
// child of `AuricleCLI`, per `Tree.firstChild(equalTo:)`), so this has to be
// listed in `AuricleCLI`'s `subcommands:` alongside the 10 real verbs.
// `shouldDisplay: false` keeps it off `auricle help`, which per the AC lists
// exactly those 10 verbs.
struct BareInvocation: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__bare-status",
        shouldDisplay: false
    )

    func run() async throws {
        let pending: [Meeting]
        do {
            let stateStore = try StateStore.production()
            pending = try await stateStore.fetchPending()
        } catch {
            writeStderr("Couldn't read meeting state: \(error).")
            throw ExitCode(2)
        }

        let summaries = pending.map {
            PendingMeetingSummary(
                id: $0.id,
                state: $0.state,
                referenceTimestamp: $0.captureStartedAt ?? $0.createdAt
            )
        }

        switch BareInvocationResolver.resolve(pending: summaries) {
        case .recording(let id, let elapsed):
            print("Recording \(id) — \(elapsed)")
        case .awaitingAttribution:
            print("Last meeting awaiting attribution: auricle attribute current")
        case .awaitingVerification:
            print("Last meeting awaiting your review: auricle keep last")
        case .nothingInFlight:
            print("Nothing in flight.")
        }
    }
}
