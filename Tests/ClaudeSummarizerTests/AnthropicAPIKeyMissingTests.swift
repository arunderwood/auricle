@testable import ClaudeSummarizer
import Foundation
@testable import Summarize
import SummarizerInterface
import Testing

/// A session no test here should reach: the key lookup fails before any
/// request is built.
private func makeClient(apiKeyProvider: @escaping AnthropicHTTPClient.APIKeyProvider) -> AnthropicHTTPClient {
    AnthropicHTTPClient(session: URLSession(configuration: .ephemeral), apiKeyProvider: apiKeyProvider, sleep: { _ in })
}

@Test func aMissingKeychainItemThrowsAPIKeyMissing() async {
    let client = makeClient(apiKeyProvider: { throw KeychainError.notFound })

    await #expect(throws: SummarizerError.apiKeyMissing) {
        _ = try await client.send(AnthropicRequest(body: Data("{}".utf8)))
    }
}

@Test func aKeychainFailureOtherThanNotFoundPropagatesUnchanged() async {
    let client = makeClient(apiKeyProvider: { throw KeychainError.unexpectedStatus(-25293) })

    await #expect(throws: KeychainError.unexpectedStatus(-25293)) {
        _ = try await client.send(AnthropicRequest(body: Data("{}".utf8)))
    }
}

/// `SummarizerError.stageErrorMessage` names the Keychain service without
/// importing `KeychainAPIKey`, so this is what keeps the two from drifting.
@Test func theMissingKeyMessageNamesTheServiceAndAccountTheKeychainReadsFrom() {
    let message = SummarizerError.apiKeyMissing.stageErrorMessage

    #expect(message.contains(KeychainAPIKey.productionService))
    #expect(message.contains(KeychainAPIKey.account))
}
