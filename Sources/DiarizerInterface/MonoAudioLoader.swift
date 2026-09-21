import AVFoundation
import Foundation

/// Reads audio as the 16 kHz mono Float samples both a diarization engine and
/// the snippet writer work in, converting whatever the file holds.
public enum MonoAudioLoader {
    public static let sampleRate = 16000.0

    public enum LoadError: Error, Equatable {
        case unreadable
    }

    /// `durationSeconds` of `nil` reads to the end. A range past the end of
    /// the file yields what remains, possibly nothing.
    public static func load(url: URL, startSeconds: Double = 0, durationSeconds: Double? = nil) throws -> [Float] {
        do {
            let file = try AVAudioFile(forReading: url)
            let inputRate = file.processingFormat.sampleRate
            guard inputRate > 0,
                  let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat)
            else {
                throw LoadError.unreadable
            }

            let startFrame = AVAudioFramePosition(max(startSeconds, 0) * inputRate)
            guard startFrame < file.length else { return [] }
            file.framePosition = startFrame
            var remaining = file.length - startFrame
            if let durationSeconds {
                remaining = min(remaining, AVAudioFramePosition(durationSeconds * inputRate))
            }

            return try convert(file: file, converter: converter, outputFormat: outputFormat, inputFrames: remaining)
        } catch {
            throw LoadError.unreadable
        }
    }

    private static func convert(
        file: AVAudioFile,
        converter: AVAudioConverter,
        outputFormat: AVAudioFormat,
        inputFrames: AVAudioFramePosition,
    ) throws -> [Float] {
        let chunkFrames: AVAudioFrameCount = 1 << 16
        var remaining = inputFrames
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(inputFrames) * sampleRate / file.processingFormat.sampleRate))

        while remaining > 0 {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining))
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: want) else { throw LoadError.unreadable }
            try file.read(into: input, frameCount: want)
            guard input.frameLength > 0 else { break }
            remaining -= AVAudioFramePosition(input.frameLength)

            let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / file.processingFormat.sampleRate) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw LoadError.unreadable }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, conversionError == nil else { throw LoadError.unreadable }
            if let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        }
        try flush(converter: converter, outputFormat: outputFormat, into: &samples)
        return samples
    }

    /// A resampler holds back the samples its filter still needs input for.
    /// Feeding `.noDataNow` between chunks leaves them there, so the end of
    /// the stream has to be signalled for the last ones to come out.
    private static func flush(converter: AVAudioConverter, outputFormat: AVAudioFormat, into samples: inout [Float]) throws {
        let capacity: AVAudioFrameCount = 1 << 12
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { throw LoadError.unreadable }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard status != .error, conversionError == nil else { throw LoadError.unreadable }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            if status == .endOfStream || output.frameLength == 0 {
                return
            }
        }
    }
}
