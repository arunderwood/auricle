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
    /// The process's one capture stage: it owns every recording the GUI makes,
    /// and hands each captured meeting to the pipeline. `nil` when the state
    /// store could not be opened.
    static let captureStage = makeCaptureStage()
    #if DEBUG
        /// Drives `Debug > Start Recording / Stop Recording` (`Cmd-Shift-R`) so
        /// the process-tap backend can be exercised before Epic 6's Record
        /// button (Story 6.2) replaces this trigger entirely. `nil` when the
        /// state store could not be opened.
        @MainActor static let debugCaptureTrigger = makeDebugCaptureTrigger()
    #endif

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
        if let stage = Self.captureStage {
            Task { await Self.recoverInterruptedCaptures(stage) }
        }
    }

    var body: some Scene {
        WindowGroup {
            if OnboardingMarker.exists(applicationSupportDirectory: .applicationSupportDirectory) {
                #if DEBUG
                    AuricleRootView(debugCaptureTrigger: Self.debugCaptureTrigger)
                #else
                    AuricleRootView()
                #endif
            } else {
                OnboardingRootView(coordinator: Self.makeOnboardingCoordinator())
            }
        }
        #if DEBUG
        .commands {
            CommandMenu("Debug") {
                let title = Self.debugCaptureTrigger?.isRecording == true ? "Stop Recording" : "Start Recording"
                Button(title) {
                    Task { await Self.debugCaptureTrigger?.toggle() }
                }
                .accessibilityLabel(title)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(Self.debugCaptureTrigger == nil)
            }
        }
        #endif
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
            writeSelfWikilink: { try ConfigWriter.set("self.wikilink", to: $0) },
            configuredSelfWikilink: { (try? Config.load())?.selfWikilink },
            fullUserName: NSFullUserName(),
            vaultTerms: { url in
                await Task.detached(priority: .userInitiated) {
                    VaultGlossaryBuilder(vaultPath: url).buildOrEmpty()
                }.value
            },
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

    /// The GUI's `Notifier` is a `UserNotificationNotifier`. The GUI's pipeline
    /// runs stop at `review-diarization`, before notify, so the one
    /// notification it posts is for a capture a revoked permission stopped.
    /// Without a configured vault there is no note to open, so no click
    /// delegate.
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
    /// `awaiting_attribution` for the user. `nonisolated`, so reading the
    /// config and waiting on the worker subprocesses stays off the main actor.
    /// No glossary: only attribute reads it, and this run stops before
    /// attribute.
    private nonisolated static func runPipelineAfterCapture(_ meetingID: MeetingID, store: StateStore, notifier: any Notifier) async {
        let log = Log(category: "app")
        let config: Config
        do {
            config = try Config.load()
        } catch {
            log.warn("config unreadable; the captured meeting was not processed", ["meetingID": .publicSafe(meetingID)])
            return
        }
        let runner = PipelineRunner(environment: PipelineRunner.Environment(
            stateStore: store,
            launcher: SubprocessStageLauncher(dispatcher: SubprocessDispatcher()),
            notifier: notifier,
            vaultPath: config.vaultPath,
            meetingsSubdir: config.meetingsSubdir,
        ))
        let result = await runner.run(meetingID: meetingID, options: RunOptions(to: .reviewDiarization))
        if result.exitCode != WorkerExitCode.success {
            log.warn("the pipeline stopped after capture", [
                "meetingID": .publicSafe(meetingID),
                "exitCode": .publicSafe(result.exitCode),
            ])
        }
    }

    #if DEBUG
        /// The opener mirrors `makeOnboardingCoordinator()`'s: one place decides
        /// what "opened successfully" means, reused rather than a second
        /// `NSWorkspace.open` call site.
        @MainActor
        private static func makeDebugCaptureTrigger() -> DebugCaptureTrigger? {
            guard let stage = captureStage else { return nil }
            let opener: URLOpener = { url in
                await (try? NotificationDelegate.openInDefaultApp(url)) != nil
            }
            return DebugCaptureTrigger(stage: stage, checker: permissionChecker, opener: opener)
        }
    #endif

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

/// `isRecording` is local view state; no capture source drives it in a
/// Release build. In Debug, `debugCaptureTrigger` (Story 5.6) is the one
/// live source until Epic 6's Record button (Story 6.2) replaces both.
private struct AuricleRootView: View {
    @State private var isRecording = false
    #if DEBUG
        /// `@State`, mirroring `OnboardingRootView`'s own `coordinator`: an
        /// `@Observable` reference type a view holds must be wrapped for SwiftUI
        /// to track it, not stored as a plain `let`.
        @State private var debugCaptureTrigger: DebugCaptureTrigger?

        init(debugCaptureTrigger: DebugCaptureTrigger?) {
            _debugCaptureTrigger = State(initialValue: debugCaptureTrigger)
        }
    #endif

    var body: some View {
        Text("auricle")
            .toolbar {
                ToolbarItem {
                    #if DEBUG
                        RecordingIndicator(isRecording: debugCaptureTrigger?.isRecording ?? isRecording)
                    #else
                        RecordingIndicator(isRecording: isRecording)
                    #endif
                }
            }
        #if DEBUG
            .alert(
                "Microphone Not Included",
                isPresented: Binding(
                    get: { debugCaptureTrigger?.microphoneDeniedAlert != nil },
                    set: { isPresented in
                        if !isPresented {
                            debugCaptureTrigger?.dismissMicrophoneDeniedAlert()
                        }
                    },
                ),
                presenting: debugCaptureTrigger?.microphoneDeniedAlert,
            ) { alert in
                if alert.settingsURL != nil {
                    Button("Open Settings") {
                        Task { await debugCaptureTrigger?.openMicrophoneSettings() }
                    }
                    .accessibilityLabel("Open Settings")
                }
                Button("OK", role: .cancel) {
                    debugCaptureTrigger?.dismissMicrophoneDeniedAlert()
                }
                .accessibilityLabel("OK")
            } message: { alert in
                Text(alert.message)
            }
        #endif
    }
}
