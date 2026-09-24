import Foundation
import Observation

/// Whether first-run onboarding is behind the user, as something the window
/// and the Debug menu can observe. The marker file is read once, at init:
/// after that, `markComplete()` is what moves the app from onboarding to
/// its main window, so the switch happens without a relaunch. The GUI holds
/// one instance and hands it to everything that gates on it.
@MainActor @Observable
public final class OnboardingProgress {
    public private(set) var isComplete: Bool

    public init(applicationSupportDirectory: URL) {
        isComplete = OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory)
    }

    /// Starts in a known state without reading any marker file.
    public init(isComplete: Bool) {
        self.isComplete = isComplete
    }

    public func markComplete() {
        isComplete = true
    }
}
