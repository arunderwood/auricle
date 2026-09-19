import Foundation
import Testing
import TranscriberInterface

@Test func defaultConfigNamesTheTurboModelAndNoFolder() {
    let config = TranscriberConfig()

    #expect(config.modelID == "whisper-large-v3-turbo")
    #expect(config.modelID == TranscriberConfig.defaultModelID)
    #expect(config.modelFolder == nil)
}

@Test func configCarriesAnExplicitModelAndFolder() {
    let folder = URL(fileURLWithPath: "/models/whisper")

    let config = TranscriberConfig(modelID: "custom", modelFolder: folder)

    #expect(config.modelID == "custom")
    #expect(config.modelFolder == folder)
}

@Test func transcriberErrorCasesDescribeThemselvesByName() {
    #expect(String(describing: TranscriberError.modelUnavailable) == "modelUnavailable")
    #expect(String(describing: TranscriberError.modelLoadFailed) == "modelLoadFailed")
    #expect(String(describing: TranscriberError.audioUnreadable) == "audioUnreadable")
    #expect(String(describing: TranscriberError.transcriptionFailed) == "transcriptionFailed")
}
