@testable import Attribute
import Core
import DiarizerInterface
import Foundation
import Testing

private struct GoldenCase: Decodable {
    struct Expected: Decodable {
        let id: String
        let speaker: String
        let applied: String
    }

    let diarization: DiarizationArtifact
    let attribution: AttributionFile
    let expected: [Expected]
}

private func label(_ source: AttributionSource?) -> String {
    switch source {
    case nil: "default"
    case .manual?: "manual"
    case let .aiSuggestion(id)?: "ai:\(id)"
    }
}

private func render(_ file: AttributionFile, _ diarization: DiarizationArtifact = threeSpeakerDiarization, transcript: CanonicalTranscript? = nil) -> RenderedTranscript {
    renderTranscript(diarization: diarization, overrides: file.segmentOverrides, splits: file.segmentSplits, speakers: file.speakers, transcript: transcript)
}

private let benSplit = SegmentSplit(
    originalSegmentId: "seg_2", source: .aiSuggestion(suggestionId: "s1"),
    splits: [
        SplitPart(newId: "seg_2.0", start: 5, end: 10, speaker: "[[Ben]]"),
        SplitPart(newId: "seg_2.1", start: 10, end: 25, speaker: "[[Sara]]"),
    ],
)

@Test func theGoldenFixtureRendersAsExpected() throws {
    let url = try #require(Bundle.module.url(forResource: "both_partial", withExtension: "json", subdirectory: "Fixtures/renderer"))
    let golden = try JSONDecoder().decode(GoldenCase.self, from: Data(contentsOf: url))
    let rendered = render(golden.attribution, golden.diarization)
    #expect(rendered.segments.map(\.id) == golden.expected.map(\.id))
    #expect(rendered.segments.map(\.speakerLabel) == golden.expected.map(\.speaker))
    #expect(rendered.segments.map { label($0.appliedFrom) } == golden.expected.map(\.applied))
}

@Test func everyCombinationOfCorrectionsAndMappingsRendersEverySegment() {
    for withOverrides in [true, false] {
        for withSplits in [true, false] {
            for namedSpeakers in [0, 1, 3] {
                assertCombination(withOverrides: withOverrides, withSplits: withSplits, namedSpeakers: namedSpeakers)
            }
        }
    }
}

private func assertCombination(withOverrides: Bool, withSplits: Bool, namedSpeakers: Int) {
    let names = ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Sara]]", "Speaker_3": "[[Kim]]"]
    let speakers = Dictionary(uniqueKeysWithValues: threeSpeakerDiarization.speakerLabels.enumerated().map { index, label in
        (label, index < namedSpeakers ? names[label] ?? label : label)
    })
    let file = AttributionFile(
        speakers: speakers,
        segmentOverrides: withOverrides ? [SegmentOverride(segmentId: "seg_3", speaker: "[[Zed]]")] : [],
        segmentSplits: withSplits ? [benSplit] : [],
    )
    let rendered = render(file).segments
    #expect(rendered.count == (withSplits ? 4 : 3))
    #expect(rendered.map(\.startSeconds) == rendered.map(\.startSeconds).sorted())
    #expect(rendered.first?.speakerLabel == (namedSpeakers >= 1 ? "[[Ben]]" : "Speaker_1"))
    #expect(rendered.last?.speakerLabel == (withOverrides ? "[[Zed]]" : (namedSpeakers >= 3 ? "[[Kim]]" : "Speaker_3")))
}

@Test func aSplitBeatsAnOverrideOnTheSameSegment() {
    let file = AttributionFile(speakers: [:], segmentOverrides: [SegmentOverride(segmentId: "seg_2", speaker: "[[Zed]]")], segmentSplits: [benSplit])
    #expect(render(file).segments.map(\.speakerLabel) == ["Speaker_1", "[[Ben]]", "[[Sara]]", "Speaker_3"])
}

@Test func aDanglingSplitAndOverrideAreIgnored() {
    let dangling = SegmentSplit(
        originalSegmentId: "seg_404", source: .manual,
        splits: [SplitPart(newId: "a", start: 0, end: 1, speaker: "[[X]]"), SplitPart(newId: "b", start: 1, end: 2, speaker: "[[Y]]")],
    )
    let file = AttributionFile(speakers: [:], segmentOverrides: [SegmentOverride(segmentId: "seg_404", speaker: "[[Z]]")], segmentSplits: [dangling])
    #expect(render(file).segments.map(\.id) == ["seg_1", "seg_2", "seg_3"])
}

@Test func aBlankSpeakerValueFallsBackToThePlaceholder() {
    let file = AttributionFile(speakers: ["Speaker_1": "  ", "Speaker_2": ""])
    #expect(render(file).segments.map(\.speakerLabel) == ["Speaker_1", "Speaker_2", "Speaker_3"])
}

@Test func renderingIsIdempotent() {
    let file = AttributionFile(speakers: ["Speaker_1": "[[Ben]]"], segmentOverrides: [SegmentOverride(segmentId: "seg_3", speaker: "[[Zed]]")], segmentSplits: [benSplit])
    #expect(render(file) == render(file))
}

@Test func unsplitSegmentsCarryTheirUtterancesWithoutTheSpeakerPrefix() {
    let file = AttributionFile(speakers: ["Speaker_1": "[[Ben]]"], segmentSplits: [benSplit])
    let rendered = render(file, transcript: threeSpeakerTranscript).segments
    #expect(rendered.map(\.text) == ["Hello there.", "", "", "Sounds good."])
}

@Test func withoutATranscriptTextIsEmpty() {
    #expect(render(AttributionFile()).segments.map(\.text) == ["", "", ""])
}

@Test func aUtteranceRangePastTheTranscriptYieldsWhatExists() {
    let diarization = DiarizationArtifact(segments: [segment("seg_1", "Speaker_1", 0, 1, utterances: 0 ... 9)])
    let rendered = render(AttributionFile(), diarization, transcript: threeSpeakerTranscript)
    #expect(rendered.segments.first?.text == "Hello there.\nLet us begin.\nSounds good.")
}

@Test func theFileRoundTripsAndIgnoresUnknownKeys() throws {
    let file = AttributionFile(speakers: ["Speaker_1": "[[Ben]]"], segmentOverrides: [SegmentOverride(segmentId: "seg_3", speaker: "[[Zed]]")], segmentSplits: [benSplit])
    #expect(try JSONDecoder().decode(AttributionFile.self, from: JSONEncoder().encode(file)) == file)
    let extra = Data(#"{"speakers":{"Speaker_1":"[[Ben]]"},"future":[1,2]}"#.utf8)
    #expect(try JSONDecoder().decode(AttributionFile.self, from: extra).speakers == ["Speaker_1": "[[Ben]]"])
}
