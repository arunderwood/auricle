import AVFoundation
import Core
import CoreML
import Foundation
import TranscriberInterface
import WhisperKit

/// A `TranscriberStrategy` backed by WhisperKit, run entirely on-device.
///
/// The model is loaded on the first call and kept for the life of the
/// process, so a later call reuses it instead of paying the load again. The
/// load is shared: two calls that both need it wait on one load rather than
/// starting two. `WhisperKit` itself is not `Sendable` and is not safe to run
/// two transcriptions on at once, so callers transcribe one file at a time.
///
/// Transcription never touches the network. The model and tokenizer are read
/// from the folder `WhisperKitModelStore` resolves, and a folder that does
/// not hold both is refused with `TranscriberError.modelUnavailable` before
/// WhisperKit is involved.
public actor WhisperKitTranscriber: TranscriberStrategy {
    /// Nothing distinguishes speakers at this point in the pipeline, so every
    /// utterance carries the same label until diarization assigns real ones.
    static let speakerLabel = "Speaker_1"

    /// Whisper marks language, task and timestamps with `<|...|>` tokens.
    /// `skipSpecialTokens` removes them from the decoded text, and this
    /// pattern removes any that still arrive inside a segment.
    private static let specialTokenPattern = "<\\|[^|>]*\\|>"

    /// `WhisperKit` is not `Sendable`. The box is what carries it out of the
    /// task that loads it; the actor is the only thing that ever uses it.
    private struct LoadedModel: @unchecked Sendable {
        let modelFolder: URL
        let kit: WhisperKit
    }

    private struct PendingLoad {
        let modelFolder: URL
        let task: Task<LoadedModel, any Error>
    }

    private let store: WhisperKitModelStore
    private var loaded: LoadedModel?
    private var pendingLoad: PendingLoad?

    /// How many times this instance has loaded a model, so a test can tell a
    /// reused model from a reloaded one.
    public private(set) var modelLoadCount = 0

    public init(store: WhisperKitModelStore = WhisperKitModelStore()) {
        self.store = store
    }

    public func transcribe(audio: URL, config: TranscriberConfig) async throws -> CanonicalTranscript {
        try await transcribeTimed(audio: audio, config: config).transcript
    }

    public func transcribeTimed(audio: URL, config: TranscriberConfig) async throws -> TimedTranscript {
        try Self.requireReadableAudio(at: audio)
        let resolved = try store.resolve(modelID: config.modelID, modelFolder: config.modelFolder)
        let model = try await loadedModel(for: resolved)

        let results: [TranscriptionResult]
        do {
            results = try await model.kit.transcribe(audioPath: audio.path, decodeOptions: Self.decodeOptions)
        } catch {
            throw TranscriberError.transcriptionFailed
        }
        return Self.timedTranscript(from: results)
    }

    // MARK: - Model loading

    private func loadedModel(for resolved: WhisperKitModelStore.ResolvedModel) async throws -> LoadedModel {
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

    private static func load(_ resolved: WhisperKitModelStore.ResolvedModel) async throws -> LoadedModel {
        do {
            return try await LoadedModel(modelFolder: resolved.modelFolder, kit: WhisperKit(kitConfig(for: resolved)))
        } catch {
            throw TranscriberError.modelLoadFailed
        }
    }

    /// `download: false` and a `modelFolder` are what keep WhisperKit off the
    /// network. `tokenizerFolder` is the store's root so WhisperKit finds the
    /// tokenizer the store provisioned there. The audio encoder and text
    /// decoder run on the Neural Engine; the mel spectrogram on the GPU.
    static func kitConfig(for resolved: WhisperKitModelStore.ResolvedModel) -> WhisperKitConfig {
        WhisperKitConfig(
            downloadBase: resolved.root,
            modelFolder: resolved.modelFolder.path,
            tokenizerFolder: resolved.root,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine,
            ),
            verbose: false,
            load: true,
            download: false,
        )
    }

    // MARK: - Decoding

    /// English only, so there is no language detection and the language token
    /// is forced. Temperature fallback is off: a fallback samples at a raised
    /// temperature, and a second run over the same audio must produce the
    /// same words.
    ///
    /// The first-token log-probability gate is off as well, and it has to be
    /// while the fallback is: WhisperKit ends a window with no text when the
    /// first sampled token falls under that gate and relies on the temperature
    /// fallback to decode it again. With no fallback the empty window is
    /// seeked past and its thirty seconds of speech vanish from the transcript
    /// without an error. On far-field meeting audio that is a tenth to a fifth
    /// of the words. Silence is still detected by `noSpeechThreshold`.
    static let decodeOptions = DecodingOptions(
        verbose: false,
        task: .transcribe,
        language: "en",
        temperature: 0,
        temperatureFallbackCount: 0,
        usePrefillPrompt: true,
        detectLanguage: false,
        skipSpecialTokens: true,
        withoutTimestamps: false,
        wordTimestamps: false,
        firstTokenLogProbThreshold: nil,
    )

    // MARK: - Mapping

    struct TimedSegment {
        let text: String
        let start: Double
        let end: Double
    }

    static func transcript(from results: [TranscriptionResult]) -> CanonicalTranscript {
        timedTranscript(from: results).transcript
    }

    static func timedTranscript(from results: [TranscriptionResult]) -> TimedTranscript {
        timedTranscript(segments: results.flatMap { $0.segments.map { TimedSegment(text: $0.text, start: Double($0.start), end: Double($0.end)) } })
    }

    /// Timings follow the utterances the builder keeps, so a segment dropped
    /// for being blank leaves no timing behind and `index` is the position in
    /// the transcript, not in the segment list.
    static func timedTranscript(segments: [TimedSegment]) -> TimedTranscript {
        let built = CanonicalTranscriptBuilder.buildReportingKeptIndices(
            segments.map { (speakerLabel: speakerLabel, text: removingSpecialTokens(from: $0.text)) },
        )
        let timings = built.keptIndices.enumerated().map { utteranceIndex, segmentIndex in
            UtteranceTiming(index: utteranceIndex, startSeconds: segments[segmentIndex].start, endSeconds: segments[segmentIndex].end)
        }
        return TimedTranscript(transcript: built.transcript, utteranceTimings: timings)
    }

    /// One utterance per segment. A segment left empty by token removal or
    /// by trimming is dropped by the builder.
    static func transcript(segmentTexts: [String]) -> CanonicalTranscript {
        CanonicalTranscriptBuilder.build(segmentTexts.map { (speakerLabel: speakerLabel, text: removingSpecialTokens(from: $0)) })
    }

    static func removingSpecialTokens(from text: String) -> String {
        text.replacingOccurrences(of: specialTokenPattern, with: "", options: .regularExpression)
    }

    private static func requireReadableAudio(at url: URL) throws {
        do {
            _ = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriberError.audioUnreadable
        }
    }
}
