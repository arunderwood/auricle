import DiarizerInterface
import Foundation
import SpeakerKit

/// Where SpeakerKit's models live on disk, and the only code in the app that
/// downloads them.
///
/// The models sit under one `root` in SpeakerKit's Hub layout
/// (`<root>/models/argmaxinc/speakerkit-coreml/...`). `resolve` only reads: a
/// diarization call that finds them missing fails with
/// `DiarizerError.modelUnavailable`, and `provision` is the separate,
/// explicit step that repairs that.
public struct SpeakerKitModelStore: Sendable {
    private static let modelRepository = "argmaxinc/speakerkit-coreml"
    /// The folders SpeakerKit's pyannote pipeline loads a model from.
    private static let modelFolderNames = ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"]

    public struct ResolvedModel: Sendable, Equatable {
        public let modelFolder: URL
        public let root: URL
    }

    public let root: URL

    /// `~/Library/Application Support/com.auricle.app/models/speakerkit`: a
    /// download the app manages itself, not something the user edits.
    public static var defaultRoot: URL {
        URL.applicationSupportDirectory
            .appending(path: "com.auricle.app", directoryHint: .isDirectory)
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "speakerkit", directoryHint: .isDirectory)
    }

    public init(root: URL = SpeakerKitModelStore.defaultRoot) {
        self.root = root
    }

    /// The folder `provision` puts the models in.
    public var repositoryFolder: URL {
        root
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: Self.modelRepository, directoryHint: .isDirectory)
    }

    /// Reads the disk and nothing else. `modelFolder`, when given, is used as
    /// is, so a model kept somewhere the store did not put it still resolves.
    /// An incomplete folder is refused either way.
    public func resolve(modelFolder: URL? = nil) throws -> ResolvedModel {
        let folder = modelFolder ?? repositoryFolder
        guard Self.modelFolderNames.allSatisfy({ hasContents(folder.appending(path: $0, directoryHint: .isDirectory)) }) else {
            throw DiarizerError.modelUnavailable
        }
        return ResolvedModel(modelFolder: folder, root: root)
    }

    public var isProvisioned: Bool {
        (try? resolve()) != nil
    }

    /// Downloads the models if they are missing, and leaves them resolvable.
    /// The one place a diarization model is fetched from the network. Every
    /// failure is reported as `modelUnavailable`: the underlying error can
    /// carry a URL.
    public func provision() async throws {
        do {
            _ = try await SpeakerKit(PyannoteConfig(
                downloadBase: root.path,
                modelRepo: Self.modelRepository,
                download: true,
                load: false,
                verbose: false,
            ))
        } catch {
            throw DiarizerError.modelUnavailable
        }
        _ = try resolve()
    }

    private func hasContents(_ folder: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return !contents.isEmpty
    }
}
