import AppUI
import Capture
import ClaudeSummarizer
import Core
import Notifications
import Permissions
import Persist
import State
import SwiftUI
import UserNotifications

/// Notification authorization is requested at runtime via UNUserNotificationCenter
/// and gated by NSUserNotificationsUsageDescription in Info.plist — macOS has no
/// entitlement key for it, so none appears in Auricle.entitlements.
@main
struct AuricleApp: App {
    /// Shared for the process so its per-category memo (AR-PAT-4) reflects
    /// every caller's checks, not just the notification path's own.
    private static let permissionChecker = PermissionChecker()
    private static let notificationDelegate = makeNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            if OnboardingMarker.exists(applicationSupportDirectory: .applicationSupportDirectory) {
                AuricleRootView()
            } else {
                OnboardingRootView(coordinator: Self.makeOnboardingCoordinator())
            }
        }
    }

    /// The one `URLOpener` (shared by `configure` and the permission steps'
    /// Open Settings) reuses `NotificationDelegate.openInDefaultApp`
    /// rather than a second `NSWorkspace.open` call site — one place decides
    /// what "opened successfully" means. Every closure here binds `AppUI` to
    /// this process's real config file, Keychain, and Application Support
    /// directory — a test builds its own `OnboardingConfigureModel` instead
    /// of relying on a default that could silently touch any of them.
    @MainActor
    private static func makeOnboardingCoordinator() -> OnboardingCoordinator {
        let opener: URLOpener = { url in
            await (try? NotificationDelegate.openInDefaultApp(url)) != nil
        }
        let configure = OnboardingConfigureModel(
            opener: opener,
            validateVaultPath: { url in
                do {
                    try VaultWriter.validateVaultPath(url)
                } catch let error as VaultWriter.WriteError {
                    throw vaultPathValidationError(from: error)
                }
            },
            writeVaultPath: { try ConfigWriter.set("vault_path", to: $0.path) },
            writeAPIKey: { try KeychainAPIKey.write($0) },
            configuredVaultPath: { (try? Config.load())?.vaultPath },
        )
        return OnboardingCoordinator(
            checker: permissionChecker,
            configure: configure,
            applicationSupportDirectory: .applicationSupportDirectory,
            opener: opener,
            permissionSteps: [
                .microphone: MicrophonePermissionStep(),
                .systemAudioCapture: SystemAudioPermissionStep(source: ProcessTapSource()),
                .notifications: NotificationsPermissionStep(),
            ],
        )
    }

    private static func vaultPathValidationError(from error: VaultWriter.WriteError) -> VaultPathValidationError {
        switch error {
        case let .vaultPathMissing(path):
            .missing(path: path)
        case let .vaultPathNotWritable(path):
            .notWritable(path: path)
        default:
            .other(String(describing: error))
        }
    }

    /// The GUI's `Notifier` is a `UserNotificationNotifier`; the pipeline that
    /// fires it is not wired into the GUI yet, so only the click side is live.
    /// Without a configured vault there is no note to open, so no delegate.
    static func makeNotifier() -> any Notifier {
        let authorization = PermissionCheckedNotificationAuthorization(permissionChecker: permissionChecker)
        return UserNotificationNotifier(center: SystemNotificationCenter(authorization: authorization))
    }

    private static func makeNotificationDelegate() -> NotificationDelegate? {
        let log = Log(category: "app")
        guard
            let config = try? Config.load(),
            let vaultRoot = config.vaultPath,
            let store = try? StateStore.production()
        else {
            log.warn("notification click handling disabled: no vault path or state store")
            return nil
        }
        return NotificationDelegate(handler: NotificationClickHandler(
            vaultRoot: vaultRoot,
            stateStore: store,
            opener: NotificationDelegate.openInDefaultApp,
        ))
    }
}

/// `isRecording` is local view state; no capture source drives it.
private struct AuricleRootView: View {
    @State private var isRecording = false

    var body: some View {
        Text("auricle")
            .toolbar {
                ToolbarItem {
                    RecordingIndicator(isRecording: isRecording)
                }
            }
    }
}
