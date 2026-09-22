import SwiftUI

/// The always-visible signal that auricle is recording (UX-DR9's privacy
/// contract surface). Reads Reduce Motion itself so every call site gets
/// NFR-A5 compliance without having to thread the environment value through.
public struct RecordingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    private let isRecording: Bool

    public init(isRecording: Bool) {
        self.isRecording = isRecording
    }

    public var body: some View {
        let appearance = recordingIndicatorAppearance(isRecording: isRecording, reduceMotion: reduceMotion)
        HStack(spacing: 4) {
            Image(systemName: appearance.systemImage)
                .foregroundStyle(appearance.tint)
                .opacity(appearance.pulse && isPulsing ? 0.7 : 1.0)
                .animation(
                    appearance.pulse
                        ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing,
                )
            Text(appearance.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(appearance.label)
        .onAppear { isPulsing = appearance.pulse }
        .onChange(of: appearance.pulse) { _, pulse in isPulsing = pulse }
    }
}
