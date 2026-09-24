import ArgumentParser
import Attribute
import Core
import Foundation
import Orchestrator
import Pipeline
import State
import VaultGlossary

/// The run logic lives in `PipelineRunner` so `swift test` reaches it; this
/// verb wires dependencies, turns SIGINT into task cancellation, and prints.
struct RunVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the pipeline forward from a meeting's current state.",
    )

    @OptionGroup var arguments: RunArguments

    func run() async throws {
        guard let meetingID = MeetingID(ulid: arguments.id) else {
            throw failure("\(arguments.id) is not a full meeting id.")
        }
        let options = try arguments.options()
        let config: Config
        do {
            config = try Config.load()
        } catch {
            throw failure("\(Config.displayPath(of: Config.defaultFileURL())) could not be read (\(type(of: error))).")
        }
        let runner = try PipelineRunner(environment: environment(config: config))

        let task = Task { await runner.run(meetingID: meetingID, options: options) }
        let interrupt = Self.cancelOnInterrupt(task)
        let result = await task.value
        interrupt.cancel()

        for line in result.lines {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        if let message = result.message {
            writeStderr("run: \(message)")
        }
        if result.exitCode != WorkerExitCode.success {
            throw ExitCode(result.exitCode)
        }
    }

    private func environment(config: Config) throws -> PipelineRunner.Environment {
        let stateStore: StateStore
        do {
            stateStore = try StateStore.subprocess()
        } catch {
            let cause = (error as? StateStoreError).map { String(describing: $0) } ?? String(describing: type(of: error))
            throw failure("could not open the state store (\(cause)).")
        }
        let glossary = config.vaultPath.map { VaultGlossaryBuilder(vaultPath: $0).buildOrEmpty() } ?? Glossary()
        return PipelineRunner.Environment(
            stateStore: stateStore,
            launcher: SubprocessStageLauncher(dispatcher: .forRunningCLI()),
            notifier: makeCLINotifier(vaultRoot: config.vaultPath ?? URL(fileURLWithPath: "/", isDirectory: true)),
            vaultPath: config.vaultPath,
            meetingsSubdir: config.meetingsSubdir,
            glossary: glossary,
        )
    }

    /// Ctrl-C cancels the run instead of killing this process, so the runner
    /// can fail an interrupted summarize before the process exits 130.
    private static func cancelOnInterrupt(_ task: Task<RunResult, Never>) -> any DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue(label: "auricle.run.sigint"))
        source.setEventHandler {
            task.cancel()
            signal(SIGINT, SIG_DFL)
        }
        source.resume()
        return source
    }

    private func failure(_ message: String) -> ExitCode {
        writeStderr("run: \(message)")
        return ExitCode(1)
    }
}
