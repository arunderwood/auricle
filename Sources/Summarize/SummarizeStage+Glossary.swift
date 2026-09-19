import Core

extension SummarizeStage {
    private static let glossaryArtifactName = "glossary.json"
    private static let glossarySchemaVersion = 1

    /// Narrows the vault glossary to what this meeting's attendees and
    /// transcript touch, and writes that part to the meeting's `glossary.json`.
    static func scopeAndRecordGlossary(
        _ glossary: Glossary,
        transcript: CanonicalTranscript,
        speakers: [String: String]?,
        for meetingID: MeetingID,
    ) -> Glossary {
        let scoped = GlossaryInjector.scope(
            glossary,
            transcript: transcript,
            attendees: AttributionSpeakers.attendeeNames(from: speakers),
        )
        writeGlossaryArtifact(scoped, for: meetingID)
        return scoped
    }

    /// A debugging surface and the wedge measurement's input, not something the
    /// note depends on: a write that fails costs that meeting its place in the
    /// measurement, never the summary.
    private static func writeGlossaryArtifact(_ glossary: Glossary, for meetingID: MeetingID) {
        try? CacheArtifactWriter.write(glossary, for: meetingID, named: glossaryArtifactName, schemaVersion: glossarySchemaVersion)
    }
}
