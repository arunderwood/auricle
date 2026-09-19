import Core
import Foundation
import Orchestrator
import State
import TranscriberInterface

/// What `__internal-stage transcribe` does once its dependencies are built:
/// the ordering of the meeting lookup, the model preparation and the stage,
/// and the mapping of every result to a process exit. It lives here rather
/// than in the CLI target because nothing under `App/` is reached by `swift
/// test`, and this is the part a regression would otherwise slip through.
///
/// The worker names no concrete transcriber. The one thing that is specific to
/// a strategy, making its model present, arrives as the `ensureModel` closure.
public enum TranscribeWorker {
    /// How the process should end. `message` is a fixed sentence or a type
    /// name, never an error's own text, because the caller writes it to
    /// stderr and a foreign error can embed a path or transcript text.
    public struct Exit: Sendable, Equatable {
        public let code: Int32
        public let message: String?

        public init(code: Int32, message: String? = nil) {
            self.code = code
            self.message = message
        }
    }

    /// Decision 1.5's state error: the state store could not be read or
    /// written, or the stage failed in a way a retry would not change.
    static let stateErrorExitCode: Int32 = 2
    /// There is no meeting with the id the caller was given.
    static let meetingNotFoundExitCode: Int32 = 3

    /// The meeting is looked up before `ensureModel` runs, so an id with no
    /// meeting behind it never starts a model download. `ensureModel` then
    /// runs before the stage's first transaction opens, so time spent
    /// preparing the model is not charged to the `transcribing` state's
    /// stale-detection budget. It cannot fail the worker: a model that is
    /// still missing afterwards is the stage's own failure to record.
    ///
    /// The exit code is `TranscribeStage.exitCode` for a stage that ran, 3 for
    /// an unknown meeting, and 2 when the state store fails underneath the
    /// stage.
    public static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        stageRunner: StageRunner,
        transcriber: any TranscriberStrategy,
        config: TranscriberConfig,
        ensureModel: @Sendable () async -> Void,
    ) async -> Exit {
        do {
            guard try await stateStore.fetchMeeting(id: meetingID.rawValue) != nil else {
                return unknownMeeting
            }
        } catch {
            return Exit(code: stateErrorExitCode, message: "could not read the meeting (\(typeName(of: error))).")
        }

        await ensureModel()

        do {
            let outcome = try await TranscribeStage.run(
                meetingID: meetingID,
                stateStore: stateStore,
                stageRunner: stageRunner,
                transcriber: transcriber,
                config: config,
            )
            return Exit(code: TranscribeStage.exitCode(for: outcome))
        } catch StateStoreError.meetingNotFound {
            return unknownMeeting
        } catch {
            return Exit(code: stateErrorExitCode, message: "could not record its progress (\(typeName(of: error))).")
        }
    }

    private static let unknownMeeting = Exit(code: meetingNotFoundExitCode, message: "no meeting has the given ID.")

    private static func typeName(of error: Error) -> String {
        String(reflecting: type(of: error))
    }
}
