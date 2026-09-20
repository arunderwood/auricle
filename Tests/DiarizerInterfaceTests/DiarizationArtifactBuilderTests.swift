import Core
import DiarizerInterface
import Foundation
import Testing

private func raw(_ speaker: Int, _ start: Double, _ end: Double) -> RawSpeakerSegment {
    RawSpeakerSegment(speaker: speaker, startSeconds: start, endSeconds: end)
}

@Test func segmentsAreIdentifiedInStartOrderAndSpeakersInOrderOfFirstAppearance() {
    let artifact = DiarizationArtifactBuilder.build(
        raw: [raw(7, 5, 9), raw(3, 0, 4), raw(7, 10, 12)],
        utteranceTimings: [],
    )

    #expect(artifact.segments.map(\.id) == ["seg_1", "seg_2", "seg_3"])
    #expect(artifact.segments.map(\.speakerLabel) == ["Speaker_1", "Speaker_2", "Speaker_2"])
    #expect(artifact.segments.map(\.startSeconds) == [0, 5, 10])
    #expect(artifact.speakerLabels == ["Speaker_1", "Speaker_2"])
}

@Test func theOutputDoesNotDependOnTheInputOrder() {
    let segments = [raw(1, 0, 3), raw(2, 2, 6), raw(1, 6, 8), raw(3, 6, 9)]

    let forward = DiarizationArtifactBuilder.build(raw: segments, utteranceTimings: [])
    let reversed = DiarizationArtifactBuilder.build(raw: segments.reversed(), utteranceTimings: [])

    #expect(forward == reversed)
}

@Test func emptyAndInvertedSegmentsAreDropped() {
    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 2, 2), raw(1, 5, 4), raw(2, 0, 1)], utteranceTimings: [])

    #expect(artifact.segments.count == 1)
    #expect(artifact.segments.first?.speakerLabel == "Speaker_1")
}

@Test func noSegmentsGiveAnEmptyArtifact() {
    let artifact = DiarizationArtifactBuilder.build(raw: [], utteranceTimings: [])

    #expect(artifact.segments.isEmpty)
    #expect(artifact.speakerLabels.isEmpty)
}

@Test func overlapRatioIsTheShareOfTheSegmentAnotherSpeakerAlsoCovers() throws {
    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 0, 10), raw(2, 8, 14)], utteranceTimings: [])

    #expect(try #require(artifact.segments.first).voiceProfile.overlapRatio == 0.2)
    #expect(try #require(artifact.segments.last).voiceProfile.overlapRatio == 0.333)
}

@Test func twoOverlappingOthersCoverTheSameStretchOnlyOnce() throws {
    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 0, 10), raw(2, 0, 5), raw(3, 3, 5)], utteranceTimings: [])

    let longest = try #require(artifact.segments.first { $0.endSeconds == 10 })
    #expect(longest.voiceProfile.overlapRatio == 0.5)
}

@Test func aSpeakersOwnConsecutiveSegmentsNeverOverlapEachOther() {
    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 0, 5), raw(1, 4, 9)], utteranceTimings: [])

    #expect(artifact.segments.allSatisfy { $0.voiceProfile.overlapRatio == 0 })
}

@Test func aSegmentLinksTheRangeOfUtterancesItOverlaps() throws {
    let timings = [
        UtteranceTiming(index: 0, startSeconds: 0, endSeconds: 2),
        UtteranceTiming(index: 1, startSeconds: 2, endSeconds: 4),
        UtteranceTiming(index: 2, startSeconds: 4, endSeconds: 6),
        UtteranceTiming(index: 3, startSeconds: 8, endSeconds: 9),
    ]

    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 1, 5), raw(2, 6, 7.5)], utteranceTimings: timings)

    #expect(try #require(artifact.segments.first).utteranceIndex == DiarizationArtifact.UtteranceRange(first: 0, last: 2))
    #expect(try #require(artifact.segments.last).utteranceIndex == nil)
}

@Test func withoutTimingsNoSegmentCarriesAnUtteranceIndex() {
    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 0, 3)], utteranceTimings: [])

    #expect(artifact.segments.allSatisfy { $0.utteranceIndex == nil })
}

@Test func theArtifactEncodesTheSnakeCaseDialect() throws {
    let artifact = DiarizationArtifactBuilder.build(
        raw: [raw(1, 0, 3)],
        utteranceTimings: [UtteranceTiming(index: 0, startSeconds: 0, endSeconds: 3)],
    )

    let data = try JSONEncoder().encode(artifact)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let segment = try #require((json["segments"] as? [[String: Any]])?.first)
    #expect(Set(segment.keys) == ["id", "speaker_label", "start_seconds", "end_seconds", "utterance_index", "voice_profile"])
    #expect((segment["voice_profile"] as? [String: Any])?.keys.sorted() == ["overlap_ratio"])
    #expect((segment["utterance_index"] as? [String: Any])?.keys.sorted() == ["first", "last"])
    #expect(try JSONDecoder().decode(DiarizationArtifact.self, from: data) == artifact)
}

@Test(arguments: [(3, 5), (5, 5), (8, 8), (10, 10), (20, 10), (0, 5), (-4, 5)])
func snippetDurationIsClampedToFiveThroughTen(requested: Int, expected: Int) {
    #expect(DiarizerConfig(snippetDurationSeconds: requested).snippetDurationSeconds == expected)
}

@Test func defaultConfigNamesTheModelAndAnEightSecondSnippet() {
    let config = DiarizerConfig()

    #expect(config.modelID == "speakerkit-pyannote")
    #expect(config.modelFolder == nil)
    #expect(config.snippetDurationSeconds == 8)
}

@Test func aSegmentThatRoundsToZeroLengthIsDropped() {
    let artifact = DiarizationArtifactBuilder.build(raw: [raw(1, 1.0000, 1.0004), raw(2, 2, 3)], utteranceTimings: [])

    #expect(artifact.segments.map(\.speakerLabel) == ["Speaker_1"])
    #expect(artifact.segments.allSatisfy { $0.endSeconds > $0.startSeconds })
}

@Test func theConfigMapsItsSnippetDurationAndFallsBackToTheDefaultWhenItCannotBeLoaded() {
    #expect(DiarizerConfig(config: Config(attribution: Config.Attribution(snippetDurationSeconds: 6))).snippetDurationSeconds == 6)
    #expect(DiarizerConfig(config: Config(attribution: Config.Attribution(snippetDurationSeconds: 20))).snippetDurationSeconds == 10)

    var reported: [String] = []
    let fallback = DiarizerConfig.loading(config: { throw ConfigError.malformed(line: 3) }, onFailure: { reported.append(String(describing: type(of: $0))) })

    #expect(fallback == DiarizerConfig())
    #expect(reported == ["ConfigError"])
    #expect(DiarizerConfig.loading(config: { Config(attribution: Config.Attribution(snippetDurationSeconds: 7)) }).snippetDurationSeconds == 7)
}
