import AppUI
import Capture
import ClaudeSummarizer
import Core
import Notifications
import Orchestrator
import Permissions
import Persist
import Pipeline
import State
import SwiftUI
import Telemetry
import UserNotifications
import VaultGlossary

/// Notification authorization is requested at runtime via UNUserNotificationCenter
/// and gated by NSUserNotificationsUsageDescription in Info.plist — macOS has no
/// entitlement key for it, so none appears in Auricle.entitlements.
@main
struct AuricleApp: App {
    /// Shared for the process so its per-category memo (AR-PAT-4) reflects
    /// every caller's checks, not just the notification path's own.
    private static let permissionChecker = PermissionChecker()
    /// The one migrated store every GUI component shares; `nil` only when the
    /// database cannot be opened, which leaves capture and notification clicks
    /// unavailable rather than crashing the app.
    private static let stateStore = makeStateStore()
    private static let notificationDelegate = makeNotificationDelegate()
    /// The GUI's only capture stage. Story 5.6's debug trigger drives it.
    static let captureStage = makeCaptureStage()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
        if let stage = Self.captureStage {
            Task { await Self.recoverInterruptedCaptures(stage) }
        }
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

    /// `configure`'s `URLOpener` reuses `NotificationDelegate.openInDefaultApp`
    /// rather than a second `NSWorkspace.open` call site — one place decides
    /// what "opened successfully" means. Every closure here binds `AppUI` to
    /// this process's real config file, Keychain, and Application Support
    /// directory — a test builds its own `OnboardingConfigureModel` instead
    /// of relying on a default that could silently touch any of them.
    @MainActor
    private static func makeOnboardingCoordinator() -> OnboardingCoordinator {
        let configure = OnboardingConfigureModel(
            opener: { url in
                await (try? NotificationDelegate.openInDefaultApp(url)) != nil
            },
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

    /// The GUI's `Notifier` is a `UserNotificationNotifier`. It tells the user
    /// about a capture a revoked permission stopped; the published-note side
    /// fires once the GUI runs the pipeline through notify. Without a
    /// configured vault there is no note to open, so no click delegate.
    static func makeNotifier() -> any Notifier {
        let authorization = PermissionCheckedNotificationAuthorization(permissionChecker: permissionChecker)
        return UserNotificationNotifier(center: SystemNotificationCenter(authorization: authorization))
    }

    private static func makeStateStore() -> StateStore? {
        do {
            return try StateStore.production()
        } catch {
            Log(category: "app").error("state store unavailable", ["reason": .sensitive(String(describing: error))])
            return nil
        }
    }

    private static func makeCaptureStage() -> CaptureStage? {
        guard let store = stateStore else { return nil }
        let notifier = makeNotifier()
        let checker = permissionChecker
        return CaptureStage(
            stateStore: store,
            stageEventLogger: StageEventLogger(stateStore: store),
            notifier: notifier,
            makeSession: { LiveCaptureSession(meetingID: $0, permissionChecker: checker) },
            onCaptured: { meetingID in
                await runPipelineAfterCapture(meetingID, store: store, notifier: notifier)
            },
        )
    }

    /// A captured meeting runs as far as `review-diarization`, which leaves it
    /// `awaiting_attribution` for the user.
    private static func runPipelineAfterCapture(_ meetingID: MeetingID, store: StateStore, notifier: any Notifier) async {
        let log = Log(category: "app")
        let config: Config
        do {
            config = try Config.load()
        } catch {
            log.warn("config unreadable; the captured meeting was not processed", ["meetingID": .publicSafe(meetingID)])
            return
        }
        let glossary = config.vaultPath.map { VaultGlossaryBuilder(vaultPath: $0).buildOrEmpty() } ?? Glossary()
        let runner = PipelineRunner(environment: PipelineRunner.Environment(
            stateStore: store,
            launcher: SubprocessStageLauncher(dispatcher: SubprocessDispatcher()),
            notifier: notifier,
            vaultPath: config.vaultPath,
            meetingsSubdir: config.meetingsSubdir,
            glossary: glossary,
        ))
        let result = await runner.run(meetingID: meetingID, options: RunOptions(to: .reviewDiarization))
        if result.exitCode != WorkerExitCode.success {
            log.warn("the pipeline stopped after capture", [
                "meetingID": .publicSafe(meetingID),
                "exitCode": .publicSafe(result.exitCode),
            ])
        }
    }

    private static func recoverInterruptedCaptures(_ stage: CaptureStage) async {
        do {
            _ = try await stage.recoverInterruptedCaptures()
        } catch {
            Log(category: "app").error("interrupted-capture recovery failed", ["reason": .sensitive(String(describing: error))])
        }
    }

    private static func makeNotificationDelegate() -> NotificationDelegate? {
        let log = Log(category: "app")
        guard
            let config = try? Config.load(),
            let vaultRoot = config.vaultPath,
            let store = stateStore
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
