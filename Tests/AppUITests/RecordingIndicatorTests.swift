@testable import AppUI
import SwiftUI
import Testing

struct RecordingIndicatorTests {
    @Test func recordingWithMotionAllowedPulses() {
        let appearance = recordingIndicatorAppearance(isRecording: true, reduceMotion: false)
        #expect(appearance.systemImage == "record.circle.fill")
        #expect(appearance.label == "Recording")
        #expect(appearance.pulse)
        #expect(appearance.tint == Color(.systemRed))
    }

    @Test func recordingWithReduceMotionSuppressesPulse() {
        let appearance = recordingIndicatorAppearance(isRecording: true, reduceMotion: true)
        #expect(appearance.systemImage == "record.circle.fill")
        #expect(appearance.label == "Recording")
        #expect(!appearance.pulse)
        #expect(appearance.tint == Color(.systemRed))
    }

    @Test func idleNeverPulsesRegardlessOfReduceMotion() {
        for reduceMotion in [false, true] {
            let appearance = recordingIndicatorAppearance(isRecording: false, reduceMotion: reduceMotion)
            #expect(appearance.systemImage == "record.circle")
            #expect(appearance.label == "Not recording")
            #expect(!appearance.pulse)
            #expect(appearance.tint == .secondary)
        }
    }

    @Test func everyStateHasANonEmptyLabel() {
        let states = [
            recordingIndicatorAppearance(isRecording: true, reduceMotion: false),
            recordingIndicatorAppearance(isRecording: true, reduceMotion: true),
            recordingIndicatorAppearance(isRecording: false, reduceMotion: false),
            recordingIndicatorAppearance(isRecording: false, reduceMotion: true),
        ]
        for appearance in states {
            #expect(!appearance.label.isEmpty)
        }
    }
}
