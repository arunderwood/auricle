import Core
import DiarizerInterface
import Foundation

/// Cuts one short clip per speaker out of the meeting audio, and the peak
/// envelope the attribution sheet draws as a waveform without decoding the
/// clip.
///
/// A clip starts with the speaker's longest segment. When that is shorter than
/// the clip length, the speaker's next-longest segments follow, so a clip is
/// shorter than requested only when the speaker has less audio than that.
public enum SnippetExtractor {
    public static let envelopeSampleCount = 200

    /// Writes `speaker_<n>.wav` and `speaker_<n>.envelope` into `directory`
    /// for each speaker with any audio, and returns how many speakers got a
    /// snippet. The directory is created owner-only if missing. Snippet files
    /// a previous run left that this run does not rewrite are removed, so the
    /// directory always holds exactly the returned count of snippets.
    public static func extract(
        artifact: DiarizationArtifact,
        audio: URL,
        directory: URL,
        durationSeconds: Int,
    ) throws -> Int {
        guard !artifact.segments.isEmpty else {
            try removeSnippets(in: directory, keeping: [])
            return 0
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var written = 0
        var keptNames: Set<String> = []
        for label in artifact.speakerLabels {
            let samples = try clip(for: label, in: artifact, audio: audio, durationSeconds: durationSeconds)
            guard !samples.isEmpty else { continue }
            let name = label.lowercased()
            try AtomicWriter.write(wavData(samples), to: directory.appendingPathComponent("\(name).wav"), permissions: 0o600)
            try AtomicWriter.write(envelopeData(samples), to: directory.appendingPathComponent("\(name).envelope"), permissions: 0o600)
            keptNames.formUnion(["\(name).wav", "\(name).envelope"])
            written += 1
        }
        try removeSnippets(in: directory, keeping: keptNames)
        return written
    }

    private static func removeSnippets(in directory: URL, keeping kept: Set<String>) throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("speaker_") && (name.hasSuffix(".wav") || name.hasSuffix(".envelope")) && !kept.contains(name) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: - Clip selection

    private static func clip(for label: String, in artifact: DiarizationArtifact, audio: URL, durationSeconds: Int) throws -> [Float] {
        let ordered = artifact.segments
            .filter { $0.speakerLabel == label }
            .sorted { lhs, rhs in
                let (lhsLength, rhsLength) = (lhs.endSeconds - lhs.startSeconds, rhs.endSeconds - rhs.startSeconds)
                return lhsLength != rhsLength ? lhsLength > rhsLength : lhs.startSeconds < rhs.startSeconds
            }

        var samples: [Float] = []
        var remaining = Double(durationSeconds)
        for segment in ordered where remaining > 0 {
            let take = min(segment.endSeconds - segment.startSeconds, remaining)
            let piece = try MonoAudioLoader.load(url: audio, startSeconds: segment.startSeconds, durationSeconds: take)
            samples += piece
            remaining -= Double(piece.count) / MonoAudioLoader.sampleRate
        }
        return samples.map { $0.isFinite ? $0 : 0 }
    }

    // MARK: - File formats

    /// 16 kHz mono 16-bit PCM in a canonical 44-byte-header WAV.
    static func wavData(_ samples: [Float]) -> Data {
        let sampleRate = UInt32(MonoAudioLoader.sampleRate)
        let dataSize = UInt32(samples.count * 2)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(littleEndian: 36 + dataSize)
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: sampleRate * 2)
        data.append(littleEndian: UInt16(2))
        data.append(littleEndian: UInt16(16))
        data.append(contentsOf: Array("data".utf8))
        data.append(littleEndian: dataSize)
        for sample in samples {
            let clamped = min(max(sample.isFinite ? sample : 0, -1), 1)
            data.append(littleEndian: UInt16(bitPattern: Int16((clamped * 32767).rounded())))
        }
        return data
    }

    /// `envelopeSampleCount` peak absolute amplitudes as little-endian
    /// Float32, one per equal slice of the clip.
    static func envelopeData(_ samples: [Float]) -> Data {
        var data = Data()
        for bucket in 0 ..< envelopeSampleCount {
            let lower = bucket * samples.count / envelopeSampleCount
            let upper = (bucket + 1) * samples.count / envelopeSampleCount
            let peak = samples[lower ..< upper].reduce(Float(0)) { max($0, abs($1)) }
            data.append(littleEndian: peak.bitPattern)
        }
        return data
    }
}

private extension Data {
    mutating func append(littleEndian value: some FixedWidthInteger) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
