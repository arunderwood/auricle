@testable import Capture
import Foundation
import Testing

/// Calls `body` with a live `UnsafePointer<UnsafeMutablePointer<Float>>`
/// over one mono channel — the shape `AudioRingBuffer.publish` expects,
/// matching both a real IOProc's raw `AudioBuffer` and
/// `AVAudioPCMBuffer.floatChannelData`.
private func withChannelPointers(_ channel0: [Float], _ body: (UnsafePointer<UnsafeMutablePointer<Float>>) -> Void) {
    var mutableChannel0 = channel0
    mutableChannel0.withUnsafeMutableBufferPointer { buffer0 in
        var pointers = [buffer0.baseAddress!]
        pointers.withUnsafeBufferPointer { pointerBuffer in
            body(UnsafePointer(pointerBuffer.baseAddress!))
        }
    }
}

/// The two-channel overload of `withChannelPointers(_:_:)`.
private func withChannelPointers(_ channel0: [Float], _ channel1: [Float], _ body: (UnsafePointer<UnsafeMutablePointer<Float>>) -> Void) {
    var mutableChannel0 = channel0
    var mutableChannel1 = channel1
    mutableChannel0.withUnsafeMutableBufferPointer { buffer0 in
        mutableChannel1.withUnsafeMutableBufferPointer { buffer1 in
            var pointers = [buffer0.baseAddress!, buffer1.baseAddress!]
            pointers.withUnsafeBufferPointer { pointerBuffer in
                body(UnsafePointer(pointerBuffer.baseAddress!))
            }
        }
    }
}

struct AudioRingBufferTests {
    @Test func publishedChunksDrainInOrderWithTheirMetadataIntact() {
        let ring = AudioRingBuffer(slotCount: 4, slotCapacityFrames: 16, maxChannels: 1)
        withChannelPointers([1, 2, 3]) { pointer in
            ring.publish(channelData: pointer, channelCount: 1, frameCount: 3, sampleRate: 48000, hostTime: 100)
        }
        withChannelPointers([4, 5]) { pointer in
            ring.publish(channelData: pointer, channelCount: 1, frameCount: 2, sampleRate: 48000, hostTime: 200)
        }

        var drained: [RawAudioChunk] = []
        ring.drainAll { drained.append($0) }

        #expect(drained.count == 2)
        #expect(drained[0].samples == [1, 2, 3])
        #expect(drained[0].hostTime == 100)
        #expect(drained[1].samples == [4, 5])
        #expect(drained[1].hostTime == 200)
    }

    @Test func multiChannelChunksDrainChannelMajor() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 16, maxChannels: 2)
        withChannelPointers([1, 2, 3], [10, 20, 30]) { pointer in
            ring.publish(channelData: pointer, channelCount: 2, frameCount: 3, sampleRate: 16000, hostTime: 1)
        }

        var drained: [RawAudioChunk] = []
        ring.drainAll { drained.append($0) }

        #expect(drained.count == 1)
        #expect(drained[0].channelCount == 2)
        #expect(drained[0].frameCount == 3)
        #expect(drained[0].samples == [1, 2, 3, 10, 20, 30])
    }

    @Test func aFullRingSilentlyDropsFurtherPublishesUntilDrained() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        for intValue in 1 ... 4 {
            let value = Float(intValue)
            withChannelPointers([value]) { pointer in
                ring.publish(channelData: pointer, channelCount: 1, frameCount: 1, sampleRate: 48000, hostTime: UInt64(value))
            }
        }

        var drained: [RawAudioChunk] = []
        ring.drainAll { drained.append($0) }

        // Only the first 2 (the ring's capacity) survive — the 3rd and
        // 4th publishes were dropped, not queued or overwritten.
        #expect(drained.count == 2)
        #expect(drained.map(\.samples) == [[1], [2]])
    }

    @Test func aChunkLargerThanSlotCapacityIsTruncatedNotDropped() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        withChannelPointers([1, 2, 3, 4, 5, 6]) { pointer in
            ring.publish(channelData: pointer, channelCount: 1, frameCount: 6, sampleRate: 48000, hostTime: 1)
        }

        var drained: [RawAudioChunk] = []
        ring.drainAll { drained.append($0) }

        #expect(drained.count == 1)
        #expect(drained[0].frameCount == 4)
        #expect(drained[0].samples == [1, 2, 3, 4])
    }

    @Test func aChannelCountPastCapacityIsDroppedEntirely() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        withChannelPointers([1], [2]) { pointer in
            ring.publish(channelData: pointer, channelCount: 2, frameCount: 1, sampleRate: 48000, hostTime: 1)
        }

        var drained: [RawAudioChunk] = []
        ring.drainAll { drained.append($0) }

        #expect(drained.isEmpty)
    }

    @Test func secondsSinceLastPublishIsZeroBeforeTheFirstPublish() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        #expect(ring.secondsSinceLastPublish(now: 1_000_000, hostTicksToSeconds: { Double($0) }) == 0)
    }

    @Test func secondsSinceLastPublishReflectsTheGapSinceTheMostRecentPublish() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        withChannelPointers([1]) { pointer in
            ring.publish(channelData: pointer, channelCount: 1, frameCount: 1, sampleRate: 48000, hostTime: 1000)
        }

        let elapsed = ring.secondsSinceLastPublish(now: 1500, hostTicksToSeconds: { Double($0) })

        #expect(elapsed == 500)
    }

    @Test func drainingAnEmptyRingCallsNothing() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        var callCount = 0
        ring.drainAll { _ in callCount += 1 }
        #expect(callCount == 0)
    }

    @Test func aFreedSlotCanBeReusedByLaterPublishes() {
        let ring = AudioRingBuffer(slotCount: 2, slotCapacityFrames: 4, maxChannels: 1)
        for intValue in 1 ... 5 {
            let value = Float(intValue)
            withChannelPointers([value]) { pointer in
                ring.publish(channelData: pointer, channelCount: 1, frameCount: 1, sampleRate: 48000, hostTime: UInt64(value))
            }
            var drained: [RawAudioChunk] = []
            ring.drainAll { drained.append($0) }
            #expect(drained.map(\.samples) == [[value]])
        }
    }
}
