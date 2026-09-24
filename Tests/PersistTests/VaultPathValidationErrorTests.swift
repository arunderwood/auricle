import Core
import Foundation
@testable import Persist
import Testing

private struct Underlying: Error {}

@Test func aMissingVaultMapsToMissing() {
    #expect(VaultPathValidationError(VaultWriter.WriteError.vaultPathMissing(path: "/v")) == .missing(path: "/v"))
}

@Test func anUnwritableVaultMapsToNotWritable() {
    #expect(VaultPathValidationError(VaultWriter.WriteError.vaultPathNotWritable(path: "/v")) == .notWritable(path: "/v"))
}

@Test(arguments: [
    VaultWriter.WriteError.meetingsSubdirIsNotADirectory(path: "/v/M"),
    .meetingsSubdirNotWritable(path: "/v/M"),
    .meetingsSubdirCreationFailed(path: "/v/M", underlying: Underlying()),
    .collisionRetriesExhausted(path: "/v/M/x.md", maxOrdinal: 3),
])
func anyOtherWriteErrorIsCarriedAsItsDescription(error: VaultWriter.WriteError) {
    #expect(VaultPathValidationError(error) == .other(String(describing: error)))
}

@Test func theMappingMatchesWhatValidationActuallyThrows() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")

    #expect(throws: VaultPathValidationError.missing(path: missing.path)) {
        do {
            try VaultWriter.validateVaultPath(missing)
        } catch let error as VaultWriter.WriteError {
            throw VaultPathValidationError(error)
        }
    }
}
