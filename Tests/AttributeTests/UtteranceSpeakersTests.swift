@testable import Attribute
import DiarizerInterface
import Testing

private func segment(_ id: String, _ speaker: String, _ range: ClosedRange<Int>?) -> DiarizedSegment {
    DiarizedSegment(
        id: id,
        speakerLabel: speaker,
        startSeconds: 0,
        endSeconds: 1,
        utteranceIndex: range.map { DiarizedUtteranceRange(first: $0.lowerBound, last: $0.upperBound) },
        voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
    )
}

private let diarization = DiarizationArtifact(segments: [
    segment("seg_1", "Speaker_1", 0 ... 1),
    segment("seg_2", "Speaker_2", 2 ... 2),
    segment("seg_3", "Speaker_1", 3 ... 3),
])

@Test func eachUtteranceTakesItsSegmentsMappedName() {
    let file = AttributionFile(speakers: ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Sara]]"])

    #expect(UtteranceSpeakers.resolve(utteranceCount: 4, diarization: diarization, file: file) == ["[[Ben]]", "[[Ben]]", "[[Sara]]", "[[Ben]]"])
}

@Test func withoutAnAttributionFileTheSegmentPlaceholdersShowThrough() {
    #expect(UtteranceSpeakers.resolve(utteranceCount: 4, diarization: diarization, file: nil) == ["Speaker_1", "Speaker_1", "Speaker_2", "Speaker_1"])
}

@Test func aSegmentOverrideWinsOverTheSpeakersMap() {
    let file = AttributionFile(
        speakers: ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Sara]]"],
        segmentOverrides: [SegmentOverride(segmentId: "seg_3", speaker: "[[Sara]]")],
    )

    #expect(UtteranceSpeakers.resolve(utteranceCount: 4, diarization: diarization, file: file)[3] == "[[Sara]]")
}

@Test func aSplitWithOneSpeakerNamesItsUtterancesAndOneWithTwoLeavesThemUnresolved() {
    let same = SegmentSplit(originalSegmentId: "seg_1", source: .manual, splits: [
        SplitPart(newId: "a", start: 0, end: 1, speaker: "[[Cy]]"),
        SplitPart(newId: "b", start: 1, end: 2, speaker: "[[Cy]]"),
    ])
    let different = SegmentSplit(originalSegmentId: "seg_1", source: .manual, splits: [
        SplitPart(newId: "a", start: 0, end: 1, speaker: "[[Cy]]"),
        SplitPart(newId: "b", start: 1, end: 2, speaker: "[[Di]]"),
    ])

    #expect(UtteranceSpeakers.resolve(utteranceCount: 4, diarization: diarization, file: AttributionFile(segmentSplits: [same]))[0] == "[[Cy]]")
    #expect(UtteranceSpeakers.resolve(utteranceCount: 4, diarization: diarization, file: AttributionFile(segmentSplits: [different]))[0] == nil)
    #expect(UtteranceSpeakers.resolve(utteranceCount: 4, diarization: diarization, file: AttributionFile(segmentSplits: [different]))[2] == "Speaker_2")
}

@Test func utterancesNoSegmentCoversAreNilAndOutOfRangeIndicesAreIgnored() {
    let sparse = DiarizationArtifact(segments: [segment("seg_1", "Speaker_1", 1 ... 9), segment("seg_2", "Speaker_2", nil)])

    #expect(UtteranceSpeakers.resolve(utteranceCount: 3, diarization: sparse, file: nil) == [nil, "Speaker_1", "Speaker_1"])
    #expect(UtteranceSpeakers.resolve(utteranceCount: 0, diarization: sparse, file: nil).isEmpty)
}

@Test func placeholderDetectionMatchesSpeakerNOnly() {
    #expect(UtteranceSpeakers.isPlaceholder("Speaker_12"))
    #expect(!UtteranceSpeakers.isPlaceholder("[[Speaker_1]]"))
    #expect(!UtteranceSpeakers.isPlaceholder("Speaker_"))
    #expect(!UtteranceSpeakers.isPlaceholder("Ben"))
}
