import DiarizerInterface
import Foundation
import Testing
@testable import WhisperKitDiarizer

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("speakerkit-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func plantModels(in folder: URL, omitting omitted: String? = nil, leavingEmpty empty: String? = nil) throws {
    for name in ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"] where name != omitted {
        let directory = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if name != empty {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("pyannote-v3", isDirectory: true), withIntermediateDirectories: true)
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
func aMissingOrEmptyModelFolderIsRefused(name: String) throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SpeakerKitModelStore(root: root)

    try plantModels(in: store.repositoryFolder, omitting: name)
    #expect(throws: DiarizerError.modelUnavailable) { try store.resolve() }

    try FileManager.default.removeItem(at: store.repositoryFolder)
    try plantModels(in: store.repositoryFolder, leavingEmpty: name)
    #expect(throws: DiarizerError.modelUnavailable) { try store.resolve() }
}
