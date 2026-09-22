import SwiftUI

/// The visual state `RecordingIndicator` renders. A pure mapping from
/// `(isRecording, reduceMotion)` so the pairing in UX-DR9 is directly
/// unit-testable without instantiating a view.
struct RecordingIndicatorAppearance {
    let systemImage: String
    let tint: Color
    let label: String
    let pulse: Bool
}

/// Idle uses the outlined symbol and secondary tint so it reads as "present but
/// inactive" rather than absent; Reduce Motion suppresses the pulse regardless
/// of recording state, per NFR-A5.
func recordingIndicatorAppearance(isRecording: Bool, reduceMotion: Bool) -> RecordingIndicatorAppearance {
    guard isRecording else {
        return RecordingIndicatorAppearance(
            systemImage: "record.circle",
            tint: .secondary,
            label: "Not recording",
            pulse: false,
        )
    }
    return RecordingIndicatorAppearance(
        systemImage: "record.circle.fill",
        tint: Color(.systemRed),
        label: "Recording",
        pulse: !reduceMotion,
    )
}
