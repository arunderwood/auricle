import Core
import DiarizerInterface
import Foundation
import Testing
@testable import WhisperKitDiarizer

func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("speakerkit-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct ModelFolderLayout {
    let folder: String
    let version: String
    let bundles: [String]
}

private let bundlesByFolder = [
    ModelFolderLayout(folder: "speaker_segmenter", version: "pyannote-v3/W8A16", bundles: ["SpeakerSegmenter.mlmodelc"]),
    ModelFolderLayout(folder: "speaker_embedder", version: "pyannote-v3/W8A16", bundles: ["SpeakerEmbedder.mlmodelc", "SpeakerEmbedderPreprocessor.mlmodelc"]),
    ModelFolderLayout(folder: "speaker_clusterer", version: "pyannote-v4/W32A32", bundles: ["PldaProjector.mlmodelc"]),
]

/// The layout a finished download leaves: one compiled bundle per model, each
/// holding the files Core ML loads it by. `omitting` leaves a folder out,
/// `leavingEmpty` leaves it with no bundles, and `truncating` leaves its first
/// bundle without `coremldata.bin`.
func plantModels(
    in folder: URL,
    omitting omitted: String? = nil,
    leavingEmpty empty: String? = nil,
    truncating truncated: String? = nil,
) throws {
    let fileManager = FileManager.default
    for entry in bundlesByFolder where entry.folder != omitted {
        let variant = folder.appendingPathComponent("\(entry.folder)/\(entry.version)", isDirectory: true)
        try fileManager.createDirectory(at: variant, withIntermediateDirectories: true)
        guard entry.folder != empty else { continue }
        for (index, bundle) in entry.bundles.enumerated() {
            let bundleFolder = variant.appendingPathComponent(bundle, isDirectory: true)
            try fileManager.createDirectory(at: bundleFolder, withIntermediateDirectories: true)
            try AtomicWriter.write(Data("{}".utf8), to: bundleFolder.appendingPathComponent("metadata.json"))
            if entry.folder == truncated, index == 0 {
                continue
            }
            try AtomicWriter.write(Data([0]), to: bundleFolder.appendingPathComponent("coremldata.bin"))
        }
    }
}

@Test func aStoreWithNothingOnDiskIsNotProvisionedAndRefusesToResolve() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)

    #expect(!store.isProvisioned)
    #expect(throws: DiarizerError.modelUnavailable) { try store.resolve() }
}

@Test func theModelsResolveFromTheHubLayoutUnderTheRoot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)
    try plantModels(in: store.repositoryFolder)

    let resolved = try store.resolve()

    #expect(store.isProvisioned)
    #expect(resolved.modelFolder == store.repositoryFolder)
    #expect(resolved.root == root)
    #expect(store.repositoryFolder.path.hasSuffix("models/argmaxinc/speakerkit-coreml"))
}

@Test func anExplicitModelFolderIsUsedAsIs() throws {
    let root = try makeRoot()
    let elsewhere = try makeRoot()
    defer {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: elsewhere)
    }
    try plantModels(in: elsewhere)

    let resolved = try SpeakerKitModelStore(root: root).resolve(modelFolder: elsewhere)

    #expect(resolved.modelFolder == elsewhere)
}

@Test(arguments: ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"])
func aMissingEmptyOrTruncatedModelFolderIsRefused(name: String) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)

    try plantModels(in: store.repositoryFolder, omitting: name)
    #expect(throws: DiarizerError.modelUnavailable) { try store.resolve() }

    try FileManager.default.removeItem(at: store.repositoryFolder)
    try plantModels(in: store.repositoryFolder, leavingEmpty: name)
    #expect(throws: DiarizerError.modelUnavailable) { try store.resolve() }

    try FileManager.default.removeItem(at: store.repositoryFolder)
    try plantModels(in: store.repositoryFolder, truncating: name)
    #expect(throws: DiarizerError.modelUnavailable) { try store.resolve() }
}

@Test func aFolderMissingOneOfItsBundlesIsRefused() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)
    try plantModels(in: store.repositoryFolder)
    try FileManager.default.removeItem(
        at: store.repositoryFolder.appendingPathComponent("speaker_embedder/pyannote-v3/W8A16/SpeakerEmbedderPreprocessor.mlmodelc"),
    )

    #expect(!store.isProvisioned)
}

@Test(arguments: ["speaker_embedder/pyannote-v3/W8A16", ".cache/huggingface/download/speaker_embedder/pyannote-v3/W8A16"])
func aFolderWithAPartialDownloadInItIsRefused(place: String) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)
    try plantModels(in: store.repositoryFolder)
    let directory = store.repositoryFolder.appendingPathComponent(place, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try AtomicWriter.write(Data(), to: directory.appendingPathComponent("0f3a.incomplete"))

    #expect(!store.isProvisioned)
}

@Test func aHubRecordOfACompletedDownloadDoesNotMakeAFolderIncomplete() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)
    try plantModels(in: store.repositoryFolder)
    try FileManager.default.createDirectory(
        at: store.repositoryFolder.appendingPathComponent(".cache/huggingface/download/speaker_embedder/pyannote-v3/W8A16", isDirectory: true),
        withIntermediateDirectories: true,
    )

    #expect(store.isProvisioned)
}
