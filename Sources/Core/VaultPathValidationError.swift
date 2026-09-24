/// A vault path failed validation, in the terms the onboarding screens show.
/// Lives in `Core` so `AppUI` can present it without depending on `Persist`,
/// and `Persist` can build it from `VaultWriter.WriteError` in one tested
/// place.
public enum VaultPathValidationError: Error, Sendable, Equatable {
    case missing(path: String)
    case notWritable(path: String)
    case other(String)
}
