import ArgumentParser
import Capture
import Core
import Foundation
import Orchestrator
import State
import Telemetry

// Builder-mode entry point (Story 4.8): not a user-facing verb, so
// `shouldDisplay: false` keeps it out of `auricle help` and shell completions,
// and it is exempt from the NFR-I7 binding contract like `__internal-stage`.
// Standard output carries the new meeting id and nothing else, so
// `id=$(auricle __internal-import call.m4a)` works.
struct ImportVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: ImportArguments.commandName,
        shouldDisplay: false,
    )

    @OptionGroup var arguments: ImportArguments

    func run() async throws {
        let id: MeetingID
        do {
            let startedAt = try arguments.startedAt.map(AudioImporter.parseStartedAt)
            let stateStore = try openStateStore()
            let importer = AudioImporter(
                stateStore: stateStore,
                stageEventLogger: StageEventLogger(stateStore: stateStore),
            )
            let source = URL(fileURLWithPath: (arguments.audioFile as NSString).expandingTildeInPath)
            id = try await importer.importAudio(from: source, startedAt: startedAt, title: arguments.title)
        } catch let exit as ExitCode {
            throw exit
        } catch let error as AudioImportError {
            throw failure(error.message)
        } catch {
            throw failure("the import failed (\(type(of: error))).")
        }
        print(id.rawValue)
    }

    /// `StateStore.subprocess` never migrates, so a missing or older database
    /// means the app has not run yet on this machine.
    private func openStateStore() throws -> StateStore {
        do {
            return try StateStore.subprocess()
        } catch {
            let cause = (error as? StateStoreError).map { String(describing: $0) } ?? String(describing: type(of: error))
            throw failure("could not open the state store (\(cause)). Launch the app once so it creates the database.")
        }
    }

    private func failure(_ message: String) -> ExitCode {
        writeStderr("\(ImportArguments.commandName): \(message)")
        return ExitCode(1)
    }
}
