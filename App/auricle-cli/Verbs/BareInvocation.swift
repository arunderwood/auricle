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
        shouldDisplay: false,
    )

    /// A reading open, so a status command never creates the database or its
    /// directory and never migrates it. No database file means the app has not
    /// run yet and there are no meetings, which is the true answer to "what is
    /// in flight". Any other failure, a schema that is not current included,
    /// keeps the error and exit 2.
    func run() async throws {
        let pending: [Meeting]
        do {
            let stateStore = try StateStore.reader()
            pending = try await stateStore.fetchPending()
        } catch StateStoreError.databaseNotFound {
            print(BareInvocationStatus.nothingInFlight.message)
            return
        } catch {
            writeStderr("Couldn't read meeting state: \(error).")
            throw ExitCode(WorkerExitCode.stateError)
        }

        let summaries = pending.map {
            PendingMeetingSummary(
                id: $0.id,
                state: $0.state,
                referenceTimestamp: $0.captureStartedAt ?? $0.createdAt,
            )
        }

        print(BareInvocationResolver.resolve(pending: summaries).message)
    }
}
