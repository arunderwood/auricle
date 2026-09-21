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
    /// The compiled model bundles SpeakerKit's pyannote pipeline loads from
    /// each model folder. A folder is complete only when every one is there
    /// with the two files a Core ML bundle cannot load without, so a download
    /// that stopped part way is told apart from a finished one.
    private static let requiredBundles: KeyValuePairs<String, [String]> = [
        "speaker_segmenter": ["SpeakerSegmenter.mlmodelc"],
        "speaker_embedder": ["SpeakerEmbedder.mlmodelc", "SpeakerEmbedderPreprocessor.mlmodelc"],
        "speaker_clusterer": ["PldaProjector.mlmodelc"],
    ]
    private static let requiredBundleFiles = ["coremldata.bin", "metadata.json"]
    /// The hub client streams a file to `<name>.incomplete` and renames it
    /// when the file is whole.
    private static let partialDownloadSuffix = ".incomplete"

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
        guard Self.incompleteFolderNames(in: folder).isEmpty else {
            throw DiarizerError.modelUnavailable
        }
        return ResolvedModel(modelFolder: folder, root: root)
    }

    public var isProvisioned: Bool {
        (try? resolve()) != nil
    }

    /// Downloads the models if they are missing or incomplete, and leaves them
    /// resolvable. The one place a diarization model is fetched from the
    /// network. Every failure is reported as `modelUnavailable`: the
    /// underlying error can carry a URL.
    ///
    /// A model folder that fails the completeness check is removed before the
    /// download, together with the hub client's record of it, so the download
    /// fetches it whole instead of trusting what a stopped one left behind.
    /// Folders that are complete are not touched.
    public func provision() async throws {
        removeIncompleteFolders()
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

    private func removeIncompleteFolders() {
        let fileManager = FileManager.default
        for name in Self.incompleteFolderNames(in: repositoryFolder) {
            try? fileManager.removeItem(at: repositoryFolder.appending(path: name, directoryHint: .isDirectory))
            let record = repositoryFolder
                .appending(path: ".cache/huggingface/download", directoryHint: .isDirectory)
                .appending(path: name, directoryHint: .isDirectory)
            try? fileManager.removeItem(at: record)
        }
    }

    private static func incompleteFolderNames(in folder: URL) -> [String] {
        requiredBundles.compactMap { name, bundles in
            let modelFolder = folder.appending(path: name, directoryHint: .isDirectory)
            return isComplete(modelFolder, requiredBundles: bundles) && !hasPartialDownload(under: folder, name: name) ? nil : name
        }
    }

    /// Bundles sit under a version and a variant folder
    /// (`pyannote-v3/W8A16/`), which are not fixed here: SpeakerKit picks the
    /// variant by OS version.
    private static func isComplete(_ modelFolder: URL, requiredBundles: [String]) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: modelFolder, includingPropertiesForKeys: nil) else { return false }
        var bundleFolders: [String: URL] = [:]
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
            bundleFolders[url.lastPathComponent] = url
            enumerator.skipDescendants()
        }
        return requiredBundles.allSatisfy { bundle in
            guard let folder = bundleFolders[bundle] else { return false }
            return requiredBundleFiles.allSatisfy { fileManager.fileExists(atPath: folder.appending(path: $0).path) }
        }
    }

    private static func hasPartialDownload(under folder: URL, name: String) -> Bool {
        let fileManager = FileManager.default
        let places = [
            folder.appending(path: name, directoryHint: .isDirectory),
            folder.appending(path: ".cache/huggingface/download", directoryHint: .isDirectory).appending(path: name, directoryHint: .isDirectory),
        ]
        return places.contains { place in
            guard let enumerator = fileManager.enumerator(at: place, includingPropertiesForKeys: nil) else { return false }
            return enumerator.contains { ($0 as? URL)?.lastPathComponent.hasSuffix(partialDownloadSuffix) == true }
        }
    }
}
