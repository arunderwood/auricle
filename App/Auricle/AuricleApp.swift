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

/// Notification authorization is requested at runtime through
/// `PermissionChecker`. macOS has no entitlement key for it, and Info.plist
/// needs no usage string for it, so neither Auricle.entitlements nor
/// Info.plist mentions notifications.
@main
struct AuricleApp: App {
    /// Shared for the process so its per-category memo (AR-PAT-4) reflects
    /// every caller's checks, not just the notification path's own.
    private static let permissionChecker = PermissionChecker()
    /// The one migrated store every GUI component shares; `nil` only when the
    /// database cannot be opened, which leaves capture and notification clicks
    /// unavailable rather than crashing the app.
    private static let stateStore = makeStateStore()
    private static let notifier = makeNotifier()
    /// Kept here because `UNUserNotificationCenter.delegate` is weak. `nil`
    /// until a vault path is configured; the main window builds it when it
    /// appears without one, so finishing onboarding enables notification
    /// clicks without a relaunch.
    @MainActor private static var notificationDelegate: NotificationDelegate?
    /// Whether onboarding is done. The window and the Debug menu both switch
    /// on it, so the Done step's Continue moves both at once.
    @MainActor static let onboardingProgress = OnboardingProgress(applicationSupportDirectory: .applicationSupportDirectory)
    /// Runs each captured meeting to `awaiting_attribution`, and at launch
    /// any stopped capture that never got its run. `nil` when the state store
    /// could not be opened.
    private static let capturePipelineLauncher = stateStore.map { store in
        CapturePipelineLauncher(
            stateStore: store,
            launcher: SubprocessStageLauncher(dispatcher: SubprocessDispatcher()),
            notifier: notifier,
        )
    }

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
        Self.installNotificationDelegateIfNeeded()
        if let stage = Self.captureStage {
            let launcher = Self.capturePipelineLauncher
            Task { await Self.settleCapturesFromEarlierRuns(stage, launcher: launcher) }
        }
    }

    var body: some Scene {
        WindowGroup {
            WindowRootView(progress: Self.onboardingProgress)
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
                .disabled(Self.debugCaptureTrigger?.isAvailable != true)
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
    fileprivate static func makeOnboardingCoordinator() -> OnboardingCoordinator {
        let opener: URLOpener = { url in
            await (try? NotificationDelegate.openInDefaultApp(url)) != nil
        }
        let configure = OnboardingConfigureModel(
            opener: opener,
            validateVaultPath: { url in
                do {
                    try VaultWriter.validateVaultPath(url)
                } catch let error as VaultWriter.WriteError {
                    throw VaultPathValidationError(error)
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
            progress: onboardingProgress,
            opener: opener,
            permissionSteps: [
                .microphone: MicrophonePermissionStep(),
                .systemAudioCapture: SystemAudioPermissionStep(source: ProcessTapSource()),
                .notifications: NotificationsPermissionStep(),
            ],
        )
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
        guard let store = stateStore, let launcher = capturePipelineLauncher else { return nil }
        let checker = permissionChecker
        return CaptureStage(
            stateStore: store,
            stageEventLogger: StageEventLogger(stateStore: store),
            notifier: notifier,
            makeSession: { LiveCaptureSession(meetingID: $0, permissionChecker: checker) },
            onCaptured: { meetingID in
                await launcher.runAfterCapture(meetingID)
            },
        )
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
            return DebugCaptureTrigger(
                stage: stage,
                endedCaptures: stage.endedCaptures,
                progress: onboardingProgress,
                checker: permissionChecker,
                opener: opener,
            )
        }
    #endif

    /// Recovery first: it relabels orphaned `recording` rows, and the resume
    /// that follows must see those as recovered, not as stopped captures.
    private static func settleCapturesFromEarlierRuns(_ stage: CaptureStage, launcher: CapturePipelineLauncher?) async {
        do {
            _ = try await stage.recoverInterruptedCaptures()
        } catch {
            Log(category: "app").error("interrupted-capture recovery failed", ["reason": .sensitive(String(describing: error))])
        }
        await launcher?.resumeStrandedCaptures()
    }

    @MainActor
    fileprivate static func installNotificationDelegateIfNeeded() {
        guard notificationDelegate == nil, let delegate = makeNotificationDelegate() else { return }
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
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

/// Onboarding until `progress` is complete, then the main window. A view
/// rather than a branch in `AuricleApp.body`, so SwiftUI re-renders it when
/// `progress` changes and the Done step's Continue needs no relaunch.
private struct WindowRootView: View {
    let progress: OnboardingProgress

    var body: some View {
        if progress.isComplete {
            #if DEBUG
                AuricleRootView(debugCaptureTrigger: AuricleApp.debugCaptureTrigger)
                    .onAppear { AuricleApp.installNotificationDelegateIfNeeded() }
            #else
                AuricleRootView()
                    .onAppear { AuricleApp.installNotificationDelegateIfNeeded() }
            #endif
        } else {
            OnboardingRootView(coordinator: AuricleApp.makeOnboardingCoordinator())
        }
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
