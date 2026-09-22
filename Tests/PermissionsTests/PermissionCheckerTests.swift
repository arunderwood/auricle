import AVFoundation
import Foundation
import os
@testable import Permissions
import Testing
import UserNotifications

/// Counts calls per closure so a test can assert "no re-query" as a call
/// count, not just a returned value that happens to match.
private final class CallCounter: Sendable {
    private let counts = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    func record(_ name: String) {
        counts.withLock { $0[name, default: 0] += 1 }
    }

    func count(_ name: String) -> Int {
        counts.withLock { $0[name] ?? 0 }
    }
}

/// Builds a `PermissionChecker` whose microphone/notifications closures are
/// canned and counted, so every assertion below drives the real actor
/// instead of a hand-rolled test double.
private func makeChecker(
    microphone: PermissionStatus = .granted,
    notifications: PermissionStatus = .granted,
    counter: CallCounter = CallCounter(),
) -> (checker: PermissionChecker, counter: CallCounter) {
    let checker = PermissionChecker(
        queryMicrophone: {
            counter.record("queryMicrophone")
            return microphone
        },
        requestMicrophone: {
            counter.record("requestMicrophone")
            return microphone
        },
        queryNotifications: {
            counter.record("queryNotifications")
            return notifications
        },
        requestNotifications: {
            counter.record("requestNotifications")
            return notifications
        },
    )
    return (checker, counter)
}

struct PermissionCheckerTests {
    @Test func systemAudioCaptureIsAlwaysUnknownWithNoOSCall() async {
        let (checker, counter) = makeChecker()
        #expect(await checker.check(.systemAudioCapture) == .unknown)
        #expect(await checker.request(.systemAudioCapture) == .unknown)
        #expect(counter.count("queryMicrophone") == 0)
        #expect(counter.count("requestMicrophone") == 0)
        #expect(counter.count("queryNotifications") == 0)
        #expect(counter.count("requestNotifications") == 0)
    }

    @Test func calendarOAuthIsAlwaysUnknownWithNoOSCall() async {
        let (checker, counter) = makeChecker()
        #expect(await checker.check(.calendarOAuth) == .unknown)
        #expect(await checker.request(.calendarOAuth) == .unknown)
        #expect(counter.count("queryMicrophone") == 0)
        #expect(counter.count("requestMicrophone") == 0)
        #expect(counter.count("queryNotifications") == 0)
        #expect(counter.count("requestNotifications") == 0)
    }

    @Test func microphoneCheckIsMemoizedAfterFirstQuery() async {
        let (checker, counter) = makeChecker(microphone: .granted)
        #expect(await checker.check(.microphone) == .granted)
        #expect(await checker.check(.microphone) == .granted)
        #expect(await checker.check(.microphone) == .granted)
        #expect(counter.count("queryMicrophone") == 1)
    }

    @Test func notificationsCheckIsMemoizedAfterFirstQuery() async {
        let (checker, counter) = makeChecker(notifications: .denied)
        #expect(await checker.check(.notifications) == .denied)
        #expect(await checker.check(.notifications) == .denied)
        #expect(counter.count("queryNotifications") == 1)
    }

    @Test func refreshClearsTheMemoSoTheNextCheckRequeries() async {
        let (checker, counter) = makeChecker(microphone: .notDetermined)
        #expect(await checker.check(.microphone) == .notDetermined)
        #expect(counter.count("queryMicrophone") == 1)
        await checker.refresh()
        #expect(await checker.check(.microphone) == .notDetermined)
        #expect(counter.count("queryMicrophone") == 2)
    }

    @Test func requestOverwritesTheMemoBeforeReturning() async {
        let (checker, counter) = makeChecker(microphone: .denied)
        #expect(await checker.check(.microphone) == .denied)
        #expect(counter.count("queryMicrophone") == 1)

        // The canned closures are fixed per checker instance, so this proves
        // overwrite ordering (request's result lands in the memo, not
        // check's stale one) rather than a changed grant, by swapping in a
        // checker whose request closure disagrees with its query closure.
        let disagreeing = PermissionChecker(
            queryMicrophone: { .denied },
            requestMicrophone: { .granted },
            queryNotifications: { .denied },
            requestNotifications: { .granted },
        )
        #expect(await disagreeing.check(.microphone) == .denied)
        #expect(await disagreeing.request(.microphone) == .granted)
        #expect(await disagreeing.check(.microphone) == .granted)
    }

    @Test func remediationDeepLinkForCalendarOAuthIsNil() {
        let (checker, _) = makeChecker()
        #expect(checker.remediationDeepLink(for: .calendarOAuth) == nil)
    }

    @Test func remediationDeepLinkForSystemAudioCapture() {
        let (checker, _) = makeChecker()
        #expect(
            checker.remediationDeepLink(for: .systemAudioCapture)
                == URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture"),
        )
    }

    @Test func remediationDeepLinkForMicrophone() {
        let (checker, _) = makeChecker()
        #expect(
            checker.remediationDeepLink(for: .microphone)
                == URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"),
        )
    }

    @Test func remediationDeepLinkForNotifications() {
        let (checker, _) = makeChecker()
        #expect(
            checker.remediationDeepLink(for: .notifications)
                == URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications"),
        )
    }

    @Test(arguments: [
        (AVAuthorizationStatus.authorized, PermissionStatus.granted),
        (AVAuthorizationStatus.denied, PermissionStatus.denied),
        (AVAuthorizationStatus.restricted, PermissionStatus.denied),
        (AVAuthorizationStatus.notDetermined, PermissionStatus.notDetermined),
    ])
    func statusMapsEveryAVAuthorizationStatus(input: AVAuthorizationStatus, expected: PermissionStatus) {
        #expect(PermissionChecker.status(for: input) == expected)
    }

    /// `.ephemeral` is `@available(macOS, unavailable)` — it can be matched in
    /// a switch (pattern matching, not construction) but not built as a value
    /// on this platform, so it has no case here.
    @Test(arguments: [
        (UNAuthorizationStatus.authorized, PermissionStatus.granted),
        (UNAuthorizationStatus.provisional, PermissionStatus.granted),
        (UNAuthorizationStatus.denied, PermissionStatus.denied),
        (UNAuthorizationStatus.notDetermined, PermissionStatus.notDetermined),
    ])
    func statusMapsEveryUNAuthorizationStatus(input: UNAuthorizationStatus, expected: PermissionStatus) {
        #expect(PermissionChecker.status(for: input) == expected)
    }

    @Test func shouldRefreshIsTrueWhenBundleIDsMatch() {
        #expect(PermissionChecker.shouldRefresh(activatedBundleID: "com.example.auricle", ownBundleID: "com.example.auricle"))
    }

    @Test func shouldRefreshIsFalseWhenBundleIDsDiffer() {
        #expect(!PermissionChecker.shouldRefresh(activatedBundleID: "com.example.other", ownBundleID: "com.example.auricle"))
    }

    @Test func shouldRefreshIsFalseWhenActivatedBundleIDIsNil() {
        #expect(!PermissionChecker.shouldRefresh(activatedBundleID: nil, ownBundleID: "com.example.auricle"))
    }

    @Test func shouldRefreshIsFalseWhenOwnBundleIDIsNil() {
        #expect(!PermissionChecker.shouldRefresh(activatedBundleID: "com.example.auricle", ownBundleID: nil))
    }

    @Test func shouldRefreshIsFalseWhenBothBundleIDsAreNil() {
        #expect(!PermissionChecker.shouldRefresh(activatedBundleID: nil, ownBundleID: nil))
    }
}
