import Foundation
import TranscriberInterface
import WhisperKit

/// Where WhisperKit's model and tokenizer live on disk, and the only code in
/// the app that downloads them.
///
/// Everything sits under one `root` in WhisperKit's own Hub layout
/// (`<root>/models/<repo id>/...`), because that layout is what WhisperKit
/// searches when it is given `root` as both its download base and its
/// tokenizer folder. Keeping to it means the tokenizer is found on disk and
/// WhisperKit never falls back to fetching it.
///
/// `resolve` only ever reads. A transcription call that finds the model
/// missing or incomplete fails with `TranscriberError.modelUnavailable`;
/// `provision` is the separate, explicit step that repairs that.
public struct WhisperKitModelStore: Sendable {
    private struct Variant {
        /// The folder name inside the model repository.
        let folderName: String
        /// The name WhisperKit's downloader matches folders against.
        let downloadName: String
    }

    private static let modelRepository = "argmaxinc/whisperkit-coreml"
    /// The repository WhisperKit takes the tokenizer of every large-v3 model
    /// from, turbo included.
    private static let tokenizerRepository = "openai/whisper-large-v3"
    private static let tokenizerFiles = ["config.json", "tokenizer_config.json", "tokenizer.json"]
    private static let coreMLModelNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    private static let variants: [String: Variant] = [
        TranscriberConfig.defaultModelID: Variant(
            folderName: "openai_whisper-large-v3-v20240930_turbo",
            downloadName: "large-v3-v20240930_turbo",
        ),
    ]

    /// What one resolved model needs to be loaded: its folder, and the root
    /// WhisperKit is told to look for the tokenizer under.
    public struct ResolvedModel: Sendable, Equatable {
        public let modelFolder: URL
        public let root: URL
    }

    public let root: URL

    /// `~/Library/Application Support/com.auricle.app/models/whisperkit`: a
    /// multi-gigabyte download the app manages itself, not something the user
    /// edits, so it belongs with the app's other machine-managed state.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "com.auricle.app", directoryHint: .isDirectory)
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "whisperkit", directoryHint: .isDirectory)
    }

    public init(root: URL = WhisperKitModelStore.defaultRoot) {
        self.root = root
    }

    /// The folder `provision` puts `modelID` in, or `nil` for an identifier
    /// this store does not know how to fetch.
    public func modelFolder(for modelID: String) -> URL? {
        guard let variant = Self.variants[modelID] else { return nil }
        return repositoryFolder(Self.modelRepository).appending(path: variant.folderName, directoryHint: .isDirectory)
    }

    /// Reads the disk and nothing else. `modelFolder`, when given, is used
    /// as is and `modelID` is not looked up, so a model kept somewhere the
    /// store did not put it still resolves. Either way an incomplete folder
    /// is refused.
    public func resolve(modelID: String, modelFolder: URL? = nil) throws -> ResolvedModel {
        guard let folder = modelFolder ?? self.modelFolder(for: modelID) else {
            throw TranscriberError.modelUnavailable
        }
        guard isComplete(folder) else {
            throw TranscriberError.modelUnavailable
        }
        return ResolvedModel(modelFolder: folder, root: root)
    }

    public func isProvisioned(modelID: String) -> Bool {
        (try? resolve(modelID: modelID)) != nil
    }

    /// Downloads the model and its tokenizer if either is missing, and
    /// leaves the model resolvable. The one place a transcription model is
    /// fetched from the network.
    ///
    /// Every failure is reported as `modelUnavailable`: a network error or a
    /// half-downloaded folder both mean the same thing to the caller, and the
    /// underlying error can carry a URL.
    public func provision(modelID: String) async throws {
        guard let variant = Self.variants[modelID] else {
            throw TranscriberError.modelUnavailable
        }
        do {
            _ = try await WhisperKit.download(
                variant: variant.downloadName,
                downloadBase: root,
                from: Self.modelRepository,
            )
            _ = try await HubApiWrapper(downloadBase: root).snapshot(
                from: HubApiWrapper.Repo(id: Self.tokenizerRepository),
                matching: Self.tokenizerFiles,
            )
        } catch {
            throw TranscriberError.modelUnavailable
        }
        _ = try resolve(modelID: modelID)
    }

    // MARK: - Completeness

    /// The three Core ML models WhisperKit loads, and a tokenizer where
    /// WhisperKit will look for one. The tokenizer matters as much as the
    /// models: without it WhisperKit downloads one during the load.
    private func isComplete(_ folder: URL) -> Bool {
        Self.coreMLModelNames.allSatisfy { hasCoreMLModel(named: $0, in: folder) } && hasTokenizer(for: folder)
    }

    /// A compiled model is a directory bundle, so an empty one is what a
    /// download killed part way leaves behind.
    private func hasCoreMLModel(named name: String, in folder: URL) -> Bool {
        let compiled = folder.appending(path: "\(name).mlmodelc", directoryHint: .isDirectory)
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: compiled.path), !contents.isEmpty {
            return true
        }
        let source = folder.appending(path: "\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel")
        return FileManager.default.fileExists(atPath: source.path)
    }

    /// The two places WhisperKit searches that this store can vouch for: next
    /// to the model, and in the Hub-layout folder under `root`.
    private func hasTokenizer(for modelFolder: URL) -> Bool {
        let candidates = [modelFolder, repositoryFolder(Self.tokenizerRepository)]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.appending(path: "tokenizer.json").path) }
    }

    private func repositoryFolder(_ repositoryID: String) -> URL {
        root.appending(path: "models", directoryHint: .isDirectory).appending(path: repositoryID, directoryHint: .isDirectory)
    }
}
