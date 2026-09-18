import Foundation
@testable import Summarize
import SummarizerInterface
import Testing

/// "café" is 5 bytes and "🚀" is 4, so a byte range and a character range
/// disagree everywhere after the first accent.
private let text = "café 🚀 ok"
private let bytes = Array(text.utf8)

private func pointer(_ start: Int, _ end: Int) -> GroundingPointer {
    GroundingPointer(transcriptStart: start, transcriptEnd: end, sourceMethod: .citations)
}

@Test func slicesByUTF8ByteRangeNotCharacterRange() {
    #expect(TranscriptSlicer.slice(pointer(0, 5), of: bytes) == .success("café"))
    #expect(TranscriptSlicer.slice(pointer(6, 10), of: bytes) == .success("🚀"))
    #expect(TranscriptSlicer.slice(pointer(11, 13), of: bytes) == .success("ok"))
}

@Test func emptyRangeAtAnyValidOffsetIsAnEmptyString() {
    #expect(TranscriptSlicer.slice(pointer(3, 3), of: bytes) == .success(""))
    #expect(TranscriptSlicer.slice(pointer(bytes.count, bytes.count), of: bytes) == .success(""))
}

@Test func outOfBoundsAndInvertedRangesAreOutOfRange() {
    #expect(TranscriptSlicer.slice(pointer(-1, 3), of: bytes) == .failure(.outOfRange))
    #expect(TranscriptSlicer.slice(pointer(0, bytes.count + 1), of: bytes) == .failure(.outOfRange))
    #expect(TranscriptSlicer.slice(pointer(5, 4), of: bytes) == .failure(.outOfRange))
}

@Test func aRangeEndingInsideAMultiByteScalarIsNotOnAScalarBoundary() {
    #expect(TranscriptSlicer.slice(pointer(0, 4), of: bytes) == .failure(.notOnScalarBoundary))
    #expect(TranscriptSlicer.slice(pointer(7, 10), of: bytes) == .failure(.notOnScalarBoundary))
}

@Test func theStrategyComparisonRendererAndTheSlicerAgree() {
    #expect(StrategyComparisonReportRenderer.sourceQuote(for: pointer(6, 10), in: bytes) == "🚀")
    #expect(StrategyComparisonReportRenderer.sourceQuote(for: pointer(0, 99), in: bytes) == StrategyComparisonReportRenderer.outOfRangePlaceholder)
    #expect(StrategyComparisonReportRenderer.sourceQuote(for: pointer(0, 4), in: bytes) == StrategyComparisonReportRenderer.notOnBoundaryPlaceholder)
}
