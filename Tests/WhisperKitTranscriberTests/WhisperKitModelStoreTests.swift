import Core
import Foundation
import Testing
import TranscriberInterface
@testable import WhisperKitTranscriber

/// A throwaway model root, removed when the test ends.
struct StoreFixture {
    let root: URL
    let store: WhisperKitModelStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("auricle-model-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = WhisperKitModelStore(root: root)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    var defaultFolder: URL {
        get throws { try #require(store.modelFolder(for: TranscriberConfig.defaultModelID)) }
    }

    var hubTokenizerFolder: URL {
        root.appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
    }

    /// A compiled model is a directory bundle; one file inside is enough to
    /// make it non-empty, which is all completeness looks for.
    func plantCompiledModel(_ name: String, in folder: URL) throws {
        let bundle = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try AtomicWriter.write(Data("model".utf8), to: bundle.appendingPathComponent("coremldata.bin"))
    }

    func plantAllModels(in folder: URL) throws {
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try plantCompiledModel(name, in: folder)
        }
    }

    func plantTokenizer(in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try AtomicWriter.write(Data("{}".utf8), to: folder.appendingPathComponent("tokenizer.json"))
    }
}

@Test func theDefaultModelResolvesToTheTurboVariantFolderUnderTheRoot() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }

    let folder = try fixture.defaultFolder

    #expect(folder.lastPathComponent == "openai_whisper-large-v3-v20240930_turbo")
    #expect(folder.path.hasPrefix(fixture.root.path))
}

@Test func anUnknownModelIDHasNoFolderAndDoesNotResolve() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }

    #expect(fixture.store.modelFolder(for: "not-a-model") == nil)
    #expect(throws: TranscriberError.modelUnavailable) {
        try fixture.store.resolve(modelID: "not-a-model")
    }
}

@Test func anEmptyRootIsNotProvisioned() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }

    #expect(!fixture.store.isProvisioned(modelID: TranscriberConfig.defaultModelID))
    #expect(throws: TranscriberError.modelUnavailable) {
        try fixture.store.resolve(modelID: TranscriberConfig.defaultModelID)
    }
}

@Test func aCompleteFolderWithATokenizerBesideTheModelResolves() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let folder = try fixture.defaultFolder
    try fixture.plantAllModels(in: folder)
    try fixture.plantTokenizer(in: folder)

    let resolved = try fixture.store.resolve(modelID: TranscriberConfig.defaultModelID)

    #expect(resolved.modelFolder == folder)
    #expect(resolved.root == fixture.root)
    #expect(fixture.store.isProvisioned(modelID: TranscriberConfig.defaultModelID))
}

@Test func aCompleteFolderWithTheTokenizerInTheHubLayoutResolves() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAllModels(in: fixture.defaultFolder)
    try fixture.plantTokenizer(in: fixture.hubTokenizerFolder)

    #expect(fixture.store.isProvisioned(modelID: TranscriberConfig.defaultModelID))
}

@Test func aFolderWithoutATokenizerIsRefused() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    try fixture.plantAllModels(in: fixture.defaultFolder)

    #expect(throws: TranscriberError.modelUnavailable) {
        try fixture.store.resolve(modelID: TranscriberConfig.defaultModelID)
    }
}

@Test(arguments: ["MelSpectrogram", "AudioEncoder", "TextDecoder"])
func aFolderMissingAnyOneModelIsRefused(missing: String) throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let folder = try fixture.defaultFolder
    for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] where name != missing {
        try fixture.plantCompiledModel(name, in: folder)
    }
    try fixture.plantTokenizer(in: folder)

    #expect(throws: TranscriberError.modelUnavailable) {
        try fixture.store.resolve(modelID: TranscriberConfig.defaultModelID)
    }
}

@Test func anEmptyCompiledModelBundleIsRefused() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let folder = try fixture.defaultFolder
    try fixture.plantAllModels(in: folder)
    try fixture.plantTokenizer(in: folder)
    let bundle = folder.appendingPathComponent("AudioEncoder.mlmodelc", isDirectory: true)
    try FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

    #expect(throws: TranscriberError.modelUnavailable) {
        try fixture.store.resolve(modelID: TranscriberConfig.defaultModelID)
    }
}

@Test func aSourcePackageModelCountsAsPresent() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let folder = try fixture.defaultFolder
    try fixture.plantCompiledModel("MelSpectrogram", in: folder)
    try fixture.plantCompiledModel("AudioEncoder", in: folder)
    let package = folder.appendingPathComponent("TextDecoder.mlpackage/Data/com.apple.CoreML", isDirectory: true)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try AtomicWriter.write(Data("model".utf8), to: package.appendingPathComponent("model.mlmodel"))
    try fixture.plantTokenizer(in: folder)

    #expect(fixture.store.isProvisioned(modelID: TranscriberConfig.defaultModelID))
}

@Test func anExplicitFolderIsUsedAsIsAndStillChecked() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
    try fixture.plantAllModels(in: elsewhere)

    #expect(throws: TranscriberError.modelUnavailable) {
        try fixture.store.resolve(modelID: "any-name", modelFolder: elsewhere)
    }

    try fixture.plantTokenizer(in: elsewhere)
    let resolved = try fixture.store.resolve(modelID: "any-name", modelFolder: elsewhere)
    #expect(resolved.modelFolder == elsewhere)
}

@Test func provisioningAnUnknownModelFailsWithoutTouchingTheNetworkOrDisk() async throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }

    await #expect(throws: TranscriberError.modelUnavailable) {
        try await fixture.store.provision(modelID: "not-a-model")
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty)
}

@Test func theDefaultRootIsMachineManagedStateUnderApplicationSupport() {
    let root = WhisperKitModelStore.defaultRoot

    #expect(root.path.contains("Application Support/com.auricle.app/models/whisperkit"))
    #expect(!root.path.contains("/.auricle"))
}
