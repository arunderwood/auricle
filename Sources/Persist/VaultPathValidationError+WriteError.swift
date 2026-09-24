import Core

public extension VaultPathValidationError {
    /// `validateVaultPath` raises only the two vault-path cases. Any other
    /// case is carried as its description, so an unexpected error still
    /// reaches the screen instead of reading as success.
    init(_ error: VaultWriter.WriteError) {
        switch error {
        case let .vaultPathMissing(path):
            self = .missing(path: path)
        case let .vaultPathNotWritable(path):
            self = .notWritable(path: path)
        default:
            self = .other(String(describing: error))
        }
    }
}
