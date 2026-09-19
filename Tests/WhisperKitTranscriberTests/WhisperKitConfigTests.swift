import CoreML
import Foundation
import Testing
import TranscriberInterface
import WhisperKit
@testable import WhisperKitTranscriber

/// The offline guarantee lives in the `WhisperKitConfig` handed to WhisperKit,
/// and nothing short of loading a model exercises it, so it is asserted on the
/// config itself.
private func resolvedDefaultModel() throws -> (fixture: StoreFixture, resolved: WhisperKitModelStore.ResolvedModel) {
    let fixture = try StoreFixture()
    let folder = try fixture.defaultFolder
    try fixture.plantAllModels(in: folder)
    try fixture.plantTokenizer(in: folder)
    return try (fixture, fixture.store.resolve(modelID: TranscriberConfig.defaultModelID))
}

@Test func theKitConfigNeverDownloadsAndLoadsFromTheResolvedFolders() throws {
    let (fixture, resolved) = try resolvedDefaultModel()
    defer { fixture.cleanUp() }

    let config = WhisperKitTranscriber.kitConfig(for: resolved)

    #expect(config.download == false)
    #expect(config.load == true)
    #expect(config.modelFolder == resolved.modelFolder.path)
    #expect(config.tokenizerFolder == resolved.root)
    #expect(config.downloadBase == resolved.root)
}

@Test func theKitConfigNamesNoModelToFetch() throws {
    let (fixture, resolved) = try resolvedDefaultModel()
    defer { fixture.cleanUp() }

    let config = WhisperKitTranscriber.kitConfig(for: resolved)

    #expect(config.model == nil)
    #expect(config.modelEndpoint == nil)
}

@Test func theKitConfigRunsTheEncoderAndDecoderOnTheNeuralEngine() throws {
    let (fixture, resolved) = try resolvedDefaultModel()
    defer { fixture.cleanUp() }

    let options = try #require(WhisperKitTranscriber.kitConfig(for: resolved).computeOptions)

    #expect(options.audioEncoderCompute == .cpuAndNeuralEngine)
    #expect(options.textDecoderCompute == .cpuAndNeuralEngine)
}

@Test func anExplicitModelFolderIsWhatTheKitConfigLoadsFrom() throws {
    let fixture = try StoreFixture()
    defer { fixture.cleanUp() }
    let elsewhere = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
    try fixture.plantAllModels(in: elsewhere)
    try fixture.plantTokenizer(in: elsewhere)
    let resolved = try fixture.store.resolve(modelID: "any-name", modelFolder: elsewhere)

    let config = WhisperKitTranscriber.kitConfig(for: resolved)

    #expect(config.modelFolder == elsewhere.path)
    #expect(config.download == false)
}
