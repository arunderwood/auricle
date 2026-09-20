import Core
import DiarizerInterface
import Foundation
import SpeakerKit

/// A `DiarizerStrategy` backed by SpeakerKit (pyannote), run entirely
/// on-device.
///
/// The models are loaded on the first call and kept for the life of the
/// process, so a later call reuses them. The load is shared: two calls that
/// both need it wait on one load. `SpeakerKit` is not `Sendable`, so callers
/// diarize one file at a time.
///
/// Diarization never touches the network: the models are read from the folder
/// `SpeakerKitModelStore` resolves, and a folder that does not hold them is
/// refused with `DiarizerError.modelUnavailable` before SpeakerKit is involved.
public actor WhisperKitDiarizer: DiarizerStrategy {
    /// `SpeakerKit` is not `Sendable`. The box carries it out of the task that
    /// loads it; the actor is the only thing that ever uses it.
    private struct LoadedModel: @unchecked Sendable {
        let modelFolder: URL
        let kit: SpeakerKit
    }

    private struct PendingLoad {
        let modelFolder: URL
        let task: Task<LoadedModel, any Error>
    }

    private let store: SpeakerKitModelStore
    private var loaded: LoadedModel?
    private var pendingLoad: PendingLoad?

    /// How many times this instance has loaded the models, so a test can tell
    /// a reused model from a reloaded one.
    public private(set) var modelLoadCount = 0

    public init(store: SpeakerKitModelStore = SpeakerKitModelStore()) {
        self.store = store
    }

    public func diarize(
        transcript _: CanonicalTranscript,
        utteranceTimings: [UtteranceTiming],
        audio: URL,
        config: DiarizerConfig,
    ) async throws -> DiarizationArtifact {
        let samples: [Float]
        do {
            samples = try MonoAudioLoader.load(url: audio)
        } catch {
            throw DiarizerError.audioUnreadable
        }
        let resolved = try store.resolve(modelFolder: config.modelFolder)
        let model = try await loadedModel(for: resolved)

        let result: DiarizationResult
        do {
            result = try await model.kit.diarize(audioArray: samples, options: Self.diarizationOptions)
        } catch {
            throw DiarizerError.diarizationFailed
        }
        return DiarizationArtifactBuilder.build(raw: Self.rawSegments(from: result.segments), utteranceTimings: utteranceTimings)
    }

    // MARK: - Model loading

    private func loadedModel(for resolved: SpeakerKitModelStore.ResolvedModel) async throws -> LoadedModel {
        if let loaded, loaded.modelFolder == resolved.modelFolder {
            return loaded
        }
        if let pendingLoad, pendingLoad.modelFolder == resolved.modelFolder {
            return try await pendingLoad.task.value
        }

        let task = Task { try await Self.load(resolved) }
        pendingLoad = PendingLoad(modelFolder: resolved.modelFolder, task: task)
        do {
            let model = try await task.value
            loaded = model
            modelLoadCount += 1
            pendingLoad = nil
            return model
        } catch {
            pendingLoad = nil
            throw error
        }
    }

    private static func load(_ resolved: SpeakerKitModelStore.ResolvedModel) async throws -> LoadedModel {
        do {
            return try await LoadedModel(modelFolder: resolved.modelFolder, kit: SpeakerKit(kitConfig(for: resolved)))
        } catch {
            throw DiarizerError.modelLoadFailed
        }
    }

    /// `download: false` and a `modelFolder` are what keep SpeakerKit off the
    /// network.
    static func kitConfig(for resolved: SpeakerKitModelStore.ResolvedModel) -> PyannoteConfig {
        PyannoteConfig(
            downloadBase: resolved.root.path,
            modelFolder: resolved.modelFolder.path,
            download: false,
            load: true,
            verbose: false,
        )
    }

    // MARK: - Mapping

    /// Overlapping speech is kept, not reconciled away: the per-segment
    /// `overlap_ratio` is measured from it.
    static let diarizationOptions = PyannoteDiarizationOptions(useExclusiveReconciliation: false)

    /// A segment SpeakerKit attributes to no one, or to several at once, has
    /// no single speaker to label and is left out.
    static func rawSegments(from segments: [SpeakerSegment]) -> [RawSpeakerSegment] {
        segments.compactMap { segment in
            segment.speaker.speakerId.map {
                RawSpeakerSegment(speaker: $0, startSeconds: Double(segment.startTime), endSeconds: Double(segment.endTime))
            }
        }
    }
}
