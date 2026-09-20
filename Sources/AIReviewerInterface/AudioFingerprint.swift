/// Identifies the audio a transcription review was made against, so a
/// suggestion file can be matched to its recording.
public struct AudioFingerprint: Codable, Sendable, Equatable {
    public static var currentSchemaVersion: Int {
        1
    }

    public let schemaVersion: Int
    public let audioSHA256: String
    public let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case audioSHA256 = "audio_sha256"
        case durationSeconds = "duration_seconds"
    }

    public init(
        schemaVersion: Int = AudioFingerprint.currentSchemaVersion,
        audioSHA256: String,
        durationSeconds: Double,
    ) {
        self.schemaVersion = schemaVersion
        self.audioSHA256 = audioSHA256
        self.durationSeconds = durationSeconds
    }
}
