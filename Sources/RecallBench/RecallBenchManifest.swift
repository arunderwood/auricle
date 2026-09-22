/// The two fields the bench reads out of `Tests/regression/ami/manifest.json`.
/// Every other field there belongs to the audio-fetching regression suite,
/// which the bench never runs: no checksum, no byte count, no audio length.
struct RecallBenchManifest: Decodable {
    let meetings: [RecallBenchManifestMeeting]

    enum CodingKeys: String, CodingKey {
        case meetings
    }
}

struct RecallBenchManifestMeeting: Decodable {
    let id: String
    /// Repo-relative directory holding `transcript.json` and `expected.json`.
    let reference: String

    enum CodingKeys: String, CodingKey {
        case id
        case reference
    }
}
