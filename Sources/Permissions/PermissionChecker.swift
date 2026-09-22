import AppKit
import AVFoundation
import Foundation
import UserNotifications

/// The single API surface for TCC/notification-permission status (AR-PAT-4,
/// architecture.md's Permission Detection section). Every OS call that reads
/// or requests permission state — `AVCaptureDevice.authorizationStatus(for:)`/
/// `.requestAccess(for:)`, `UNUserNotificationCenter().notificationSettings()`/
/// `.requestAuthorization(options:)`, `CGPreflightScreenCaptureAccess()`,
/// `CGRequestScreenCaptureAccess()` — happens only behind this protocol,
/// enforced by `.swiftlint.yml`'s `permission_checker_bypass` rule.
public protocol PermissionChecking: Sendable {
    /// Memoized: returns the cached status for `category` if this process has
    /// already queried it, otherwise queries and caches. Never prompts.
    func check(_ category: TCCCategory) async -> PermissionStatus
    /// Prompts the OS if the category supports one, and overwrites the memo
    /// with the result before returning it.
    func request(_ category: TCCCategory) async -> PermissionStatus
    /// Clears the memo so the next `check`/`request` re-queries instead of
    /// returning a stale cached value.
    func refresh() async
    /// The System Settings deep link that remediates a denied/not-determined
    /// `category`. `nil` for `.calendarOAuth`, which remediates through a
    /// browser OAuth flow, not System Settings.
    func remediationDeepLink(for category: TCCCategory) -> URL?
}

/// `actor` gives the memo dictionary mutual-exclusion under Swift 6.3 strict
/// concurrency, the same reference-semantics-plus-safe-access reasoning as
/// `State`'s `StateStore`. The microphone/notifications OS queries are
/// injected closures — mirroring `Core/Log`'s `sink` closure — so
/// `Tests/PermissionsTests` drives every code path without live TCC state or
/// a real notification prompt.
public actor PermissionChecker: PermissionChecking {
    private var memo: [TCCCategory: PermissionStatus] = [:]
    private let queryMicrophone: @Sendable () async -> PermissionStatus
    private let requestMicrophone: @Sendable () async -> PermissionStatus
    private let queryNotifications: @Sendable () async -> PermissionStatus
    private let requestNotifications: @Sendable () async -> PermissionStatus
    /// Held only so it isn't deallocated (which would stop delivery) and so
    /// `deinit` can unregister it. `nonisolated(unsafe)`: written once,
    /// synchronously, from `init` before any concurrent access is possible,
    /// and only ever read/cleared from `deinit`, which for an actor is
    /// always nonisolated.
    private nonisolated(unsafe) var settingsChangeObserver: NSObjectProtocol?

    /// The production checker: real AVFoundation/UserNotifications queries.
    public init() {
        self.init(
            queryMicrophone: { PermissionChecker.status(for: AVCaptureDevice.authorizationStatus(for: .audio)) },
            requestMicrophone: {
                await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
            },
            queryNotifications: {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                return PermissionChecker.status(for: settings.authorizationStatus)
            },
            requestNotifications: {
                let granted = await (try? UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound])) ?? false
                return granted ? .granted : .denied
            },
        )
    }

    /// `Tests/PermissionsTests` supplies canned closures here instead of the
    /// live AVFoundation/UserNotifications ones `init()` wires up.
    init(
        queryMicrophone: @escaping @Sendable () async -> PermissionStatus,
        requestMicrophone: @escaping @Sendable () async -> PermissionStatus,
        queryNotifications: @escaping @Sendable () async -> PermissionStatus,
        requestNotifications: @escaping @Sendable () async -> PermissionStatus,
    ) {
        self.queryMicrophone = queryMicrophone
        self.requestMicrophone = requestMicrophone
        self.queryNotifications = queryNotifications
        self.requestNotifications = requestNotifications
        // Registers synchronously so no activation between construction and
        // this call is silently missed. Only the closure body's `refresh()`
        // call needs actor isolation; `addObserver` itself does not.
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil,
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard
                PermissionChecker.shouldRefresh(
                    activatedBundleID: activated?.bundleIdentifier,
                    ownBundleID: Bundle.main.bundleIdentifier,
                )
            else { return }
            Task { await self?.refresh() }
        }
        settingsChangeObserver = observer
    }

    deinit {
        if let settingsChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(settingsChangeObserver)
        }
    }

    public func check(_ category: TCCCategory) async -> PermissionStatus {
        switch category {
        case .systemAudioCapture, .calendarOAuth:
            return .unknown
        case .microphone:
            if let cached = memo[.microphone] {
                return cached
            }
            let status = await queryMicrophone()
            // A concurrent `request(.microphone)` may have completed and
            // written a newer status while this call was suspended above;
            // don't clobber it with this now-stale result.
            if memo[.microphone] == nil {
                memo[.microphone] = status
            }
            return memo[.microphone] ?? status
        case .notifications:
            if let cached = memo[.notifications] {
                return cached
            }
            let status = await queryNotifications()
            // See the .microphone case: don't clobber a newer concurrent
            // `request(.notifications)` result.
            if memo[.notifications] == nil {
                memo[.notifications] = status
            }
            return memo[.notifications] ?? status
        }
    }

    public func request(_ category: TCCCategory) async -> PermissionStatus {
        switch category {
        case .systemAudioCapture, .calendarOAuth:
            return .unknown
        case .microphone:
            let status = await requestMicrophone()
            memo[.microphone] = status
            return status
        case .notifications:
            let status = await requestNotifications()
            memo[.notifications] = status
            return status
        }
    }

    public func refresh() {
        memo.removeAll()
    }

    public nonisolated func remediationDeepLink(for category: TCCCategory) -> URL? {
        switch category {
        case .systemAudioCapture:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Notifications")
        case .calendarOAuth:
            nil
        }
    }

    /// macOS has no notification for "a TCC grant changed"; the closest
    /// AppKit-broadcast signal is our own app regaining focus, which is what
    /// happens right after the user grants or denies something in System
    /// Settings and switches back. `true` only when both bundle IDs are
    /// present and match, so an unrelated app switch — or a notification
    /// missing either ID — doesn't invalidate the memo for no reason.
    static func shouldRefresh(activatedBundleID: String?, ownBundleID: String?) -> Bool {
        guard let activatedBundleID, let ownBundleID else { return false }
        return activatedBundleID == ownBundleID
    }

    static func status(for authorizationStatus: AVAuthorizationStatus) -> PermissionStatus {
        switch authorizationStatus {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    static func status(for authorizationStatus: UNAuthorizationStatus) -> PermissionStatus {
        switch authorizationStatus {
        case .authorized, .provisional: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        case .ephemeral: .granted
        @unknown default: .unknown
        }
    }
}
