import SummarizerInterface

/// The one place a `GroundingPointer` becomes transcript text. A pointer is a
/// UTF-8 byte range (`GroundingPointer.transcriptStart`/`transcriptEnd`), not
/// a `String` character range, so the slice is taken over the transcript's
/// UTF-8 bytes; callers that slice many ranges from one transcript pass the
/// same byte array to each call instead of re-encoding it.
enum TranscriptSlicer {
    enum SliceError: Error, Equatable {
        /// Out of bounds or inverted.
        case outOfRange
        /// In bounds, but an end falls inside a multi-byte scalar.
        case notOnScalarBoundary
    }

    static func slice(_ pointer: GroundingPointer, of transcriptBytes: [UInt8]) -> Result<String, SliceError> {
        slice(start: pointer.transcriptStart, end: pointer.transcriptEnd, of: transcriptBytes)
    }

    /// `end` is exclusive, matching every byte range in the transcript contract.
    static func slice(start: Int, end: Int, of transcriptBytes: [UInt8]) -> Result<String, SliceError> {
        guard start >= 0, start <= end, end <= transcriptBytes.count else {
            return .failure(.outOfRange)
        }
        guard let text = String(bytes: transcriptBytes[start ..< end], encoding: .utf8) else {
            return .failure(.notOnScalarBoundary)
        }
        return .success(text)
    }
}
