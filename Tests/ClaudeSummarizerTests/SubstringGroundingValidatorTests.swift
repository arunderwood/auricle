@testable import ClaudeSummarizer
import Core
import SummarizerInterface
import Testing

private func makeTranscript(text: String) -> CanonicalTranscript {
    CanonicalTranscript(text: text, utterances: [])
}

@Test func quoteFoundReturnsUTF8ByteOffsetsWithSubstringSourceMethod() {
    let transcript = makeTranscript(text: "hello world")

    let pointer = SubstringGroundingValidator.validate(quote: "world", in: transcript)

    #expect(pointer == GroundingPointer(transcriptStart: 6, transcriptEnd: 11, sourceMethod: .substring))
}

/// "café " is 4 characters but 6 UTF-8 bytes (`é` is a 2-byte sequence) —
/// proves the offsets are byte offsets, not `String` character/grapheme-
/// cluster positions, which would place "world" one position too early.
@Test func quoteFoundAfterAMultiByteUnicodePrefixReturnsByteOffsetsNotCharacterCounts() {
    let transcript = makeTranscript(text: "café world")

    let pointer = SubstringGroundingValidator.validate(quote: "world", in: transcript)

    #expect(pointer?.transcriptStart == 6)
    #expect(pointer?.transcriptEnd == 11)
}

@Test func quoteNotPresentReturnsNil() {
    let transcript = makeTranscript(text: "hello world")

    #expect(SubstringGroundingValidator.validate(quote: "goodbye", in: transcript) == nil)
}

@Test func quoteOccurringMoreThanOnceResolvesToTheFirstMatch() {
    let transcript = makeTranscript(text: "repeat this, then repeat this again")

    let pointer = SubstringGroundingValidator.validate(quote: "repeat this", in: transcript)

    #expect(pointer?.transcriptStart == 0)
    #expect(pointer?.transcriptEnd == 11)
}

@Test func caseSensitiveSearchDoesNotMatchADifferentlyCasedOccurrence() {
    let transcript = makeTranscript(text: "Hello world")

    #expect(SubstringGroundingValidator.validate(quote: "hello world", in: transcript) == nil)
}
