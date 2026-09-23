@testable import AppUI
import Capture
@testable import Core
import Foundation
import os
import Permissions
import Testing

// MARK: - Test doubles

private final class Recorder<Value: Sendable>: Sendable {
    private let lock = OSAllocatedUnfairLock<[Value]>(initialState: [])

    func record(_ value: Value) {
        lock.withLock { $0.append(value) }
    }

    var values: [Value] {
        lock.withLock { $0 }
    }
}

/// Answers every `request` with `requestResult` and every deep-link lookup
/// with `deepLinks[category]`, recording each requested category.
private final class FakePermissionChecker: PermissionChecking {
    private let requestResult: PermissionStatus
    private let deepLinks: [TCCCategory: URL]
    private let requested = Recorder<TCCCategory>()

    init(requestResult: PermissionStatus = .granted, deepLinks: [TCCCategory: URL] = [:]) {
        self.requestResult = requestResult
        self.deepLinks = deepLinks
    }

    var categoriesRequested: [TCCCategory] {
        requested.values
    }

    func check(_: TCCCategory) async -> PermissionStatus {
        .notDetermined
    }

    func request(_ category: TCCCategory) async -> PermissionStatus {
        requested.record(category)
        return requestResult
    }

    func refresh() async {}

    func remediationDeepLink(for category: TCCCategory) -> URL? {
        deepLinks[category]
    }
}

private struct ProbeFailure: Error {}

/// Counts `start`/`stop` calls; no Core Audio involved. `failOnStart` makes
/// `start()` throw, standing in for a tap that couldn't be built.
private final class FakeSystemAudioSource: SystemAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private let failOnStart: Bool
    private var starts = 0
    private var stops = 0

    init(failOnStart: Bool = false) {
        self.failOnStart = failOnStart
    }

    /// No ring of its own to lose chunks from — always reports no loss.
    var ringLossStats: RingLossStats {
        RingLossStats()
    }

    var startCallCount: Int {
        lock.withLock { starts }
    }

    var stopCallCount: Int {
        lock.withLock { stops }
    }

    func start() throws {
        lock.withLock { starts += 1 }
        if failOnStart {
            throw ProbeFailure()
        }
    }

    func stop() {
        lock.withLock { stops += 1 }
    }

    func drain(_: (RawAudioChunk) -> Void) {}

    func rebuild() throws {}
}

private final class LogRecorder: Sendable {
    struct Record: Sendable, Equatable {
        let level: OSLogType
        let message: String
    }

    private let recorded = OSAllocatedUnfairLock<[Record]>(initialState: [])

    var log: Log {
        Log(category: "test") { level, message in
            self.recorded.withLock { $0.append(Record(level: level, message: message)) }
        }
    }

    var records: [Record] {
        recorded.withLock { $0 }
    }
}

/// A Microphone step whose `request` suspends until the test calls
/// `release(_:)`, so a test can change the coordinator's step mid-request.
private final class GatedPermissionStep: OnboardingPermissionStep, Sendable {
    let category: TCCCategory = .microphone
    private let pending = OSAllocatedUnfairLock<CheckedContinuation<OnboardingPermissionOutcome, Never>?>(initialState: nil)

    var isSuspended: Bool {
        pending.withLock { $0 != nil }
    }

    func request(using _: PermissionChecking) async -> OnboardingPermissionOutcome {
        await withCheckedContinuation { continuation in
            pending.withLock { $0 = continuation }
        }
    }

    func release(_ outcome: OnboardingPermissionOutcome) {
        let continuation = pending.withLock { current in
            defer { current = nil }
            return current
        }
        continuation?.resume(returning: outcome)
    }
}

private let settingsLinks: [TCCCategory: URL] = [
    .microphone: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!,
    .systemAudioCapture: URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")!,
    .notifications: URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!,
]

@MainActor
private func makeCoordinator(
    checker: FakePermissionChecker,
    source: FakeSystemAudioSource = FakeSystemAudioSource(),
    log: Log = Log(category: "test"),
    opener: @escaping URLOpener = { _ in true },
) -> OnboardingCoordinator {
    OnboardingCoordinator(
        checker: checker,
        configure: OnboardingConfigureModel(
            opener: { _ in true },
            validateVaultPath: { _ in },
            writeVaultPath: { _ in },
            writeAPIKey: { _ in },
            configuredVaultPath: { nil },
            writeSelfWikilink: { _ in },
            configuredSelfWikilink: { nil },
            fullUserName: "Jordan Lee",
            vaultTerms: { _ in Glossary() },
        ),
        applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
        opener: opener,
        permissionSteps: [
            .microphone: MicrophonePermissionStep(),
            .systemAudioCapture: SystemAudioPermissionStep(source: source, log: log),
            .notifications: NotificationsPermissionStep(),
        ],
    )
}

/// Advances from `.welcome` until `coordinator.step == target`.
@MainActor
private func walk(_ coordinator: OnboardingCoordinator, to target: OnboardingStep) {
    while coordinator.step != target {
        coordinator.advance()
    }
}

// MARK: - PermissionStepContent

struct PermissionStepContentTests {
    @Test("Before any request: a why line and only the request button", arguments: [
        (TCCCategory.microphone, "Grant Microphone access"),
        (.systemAudioCapture, "Allow System Audio Recording"),
        (.notifications, "Allow notifications"),
    ])
    func beforeRequestOffersOnlyTheRequest(category: TCCCategory, requestTitle: String) throws {
        let content = try #require(PermissionStepContent.make(category: category, status: nil))
        #expect(!content.whyLine.isEmpty)
        #expect(content.requestButtonTitle == requestTitle)
        #expect(content.actions == [.request])
        #expect(content.followUp == nil)
    }

    @Test("System Audio's standing note shows at every status", arguments: [
        PermissionStatus?.none, .granted, .denied, .notDetermined, .unknown,
    ])
    func systemAudioStandingNoteAtEveryStatus(status: PermissionStatus?) throws {
        let content = try #require(PermissionStepContent.make(category: .systemAudioCapture, status: status))
        #expect(content.standingNote == "Without it, recordings contain only your microphone.")
    }

    @Test("System Audio's follow-up never claims the grant succeeded", arguments: [
        PermissionStatus.granted, .denied, .notDetermined, .unknown,
    ])
    func systemAudioFollowUpAlwaysHedges(status: PermissionStatus) throws {
        let content = try #require(PermissionStepContent.make(category: .systemAudioCapture, status: status))
        #expect(content.followUp == PermissionStepContent.systemAudioHedgeMessage)
        #expect(content.followUp?.hasPrefix("If you chose Allow") == true)
        #expect(content.actions == [.openSettings, .continueOnward])
    }

    @Test func microphoneTryAgainOnlyWhileNotDetermined() throws {
        let notDetermined = try #require(PermissionStepContent.make(category: .microphone, status: .notDetermined))
        #expect(notDetermined.actions == [.openSettings, .skip, .tryAgain])
        for status in [PermissionStatus.denied, .unknown, .granted] {
            let content = try #require(PermissionStepContent.make(category: .microphone, status: status))
            #expect(!content.actions.contains(.tryAgain))
        }
    }

    @Test("Microphone's non-granted results offer Open Settings and Skip", arguments: [
        PermissionStatus.denied, .unknown,
    ])
    func microphoneNonGrantedContent(status: PermissionStatus) throws {
        let content = try #require(PermissionStepContent.make(category: .microphone, status: status))
        #expect(content.followUp == PermissionStepContent.microphoneDeniedMessage)
        #expect(content.actions == [.openSettings, .skip])
    }

    @Test("Notifications' non-granted results show the silent copy and only Continue", arguments: [
        PermissionStatus.denied, .notDetermined, .unknown,
    ])
    func notificationsNonGrantedContent(status: PermissionStatus) throws {
        let content = try #require(PermissionStepContent.make(category: .notifications, status: status))
        #expect(content.followUp == PermissionStepContent.notificationsDeniedMessage)
        #expect(content.actions == [.continueOnward])
    }

    @Test func notificationsGrantedHasNoFollowUp() throws {
        let content = try #require(PermissionStepContent.make(category: .notifications, status: .granted))
        #expect(content.followUp == nil)
    }

    @Test func calendarOAuthHasNoOnboardingContent() {
        #expect(PermissionStepContent.make(category: .calendarOAuth, status: nil) == nil)
    }
}

// MARK: - Microphone

@MainActor
struct MicrophonePermissionStepTests {
    @Test func grantedAdvancesToSystemAudio() async {
        let checker = FakePermissionChecker(requestResult: .granted)
        let coordinator = makeCoordinator(checker: checker)
        walk(coordinator, to: .microphone)

        await coordinator.perform(.request)

        #expect(coordinator.step == .systemAudio)
        #expect(checker.categoriesRequested == [.microphone])
    }

    @Test func deniedRemainsWithRemediationAndNoTryAgain() async throws {
        let coordinator = makeCoordinator(checker: FakePermissionChecker(requestResult: .denied))
        walk(coordinator, to: .microphone)

        await coordinator.perform(.request)

        #expect(coordinator.step == .microphone)
        #expect(coordinator.permissionStatus == .denied)
        let content = try #require(coordinator.permissionContent)
        #expect(content.followUp == PermissionStepContent.microphoneDeniedMessage)
        #expect(content.actions == [.openSettings, .skip])
        #expect(content.skipCaption == "Recordings will have system audio only.")
    }

    @Test func notDeterminedRemainsWithTryAgain() async throws {
        let coordinator = makeCoordinator(checker: FakePermissionChecker(requestResult: .notDetermined))
        walk(coordinator, to: .microphone)

        await coordinator.perform(.request)

        #expect(coordinator.step == .microphone)
        let content = try #require(coordinator.permissionContent)
        #expect(content.followUp == PermissionStepContent.microphoneDeniedMessage)
        #expect(content.actions == [.openSettings, .skip, .tryAgain])
    }

    @Test func tryAgainRequestsMicrophoneAgain() async {
        let checker = FakePermissionChecker(requestResult: .notDetermined)
        let coordinator = makeCoordinator(checker: checker)
        walk(coordinator, to: .microphone)

        await coordinator.perform(.request)
        await coordinator.perform(.tryAgain)

        #expect(checker.categoriesRequested == [.microphone, .microphone])
        #expect(coordinator.step == .microphone)
    }

    @Test func skipAdvancesToSystemAudioAndResetsStatus() async throws {
        let coordinator = makeCoordinator(checker: FakePermissionChecker(requestResult: .denied))
        walk(coordinator, to: .microphone)
        await coordinator.perform(.request)

        await coordinator.perform(.skip)

        #expect(coordinator.step == .systemAudio)
        #expect(coordinator.permissionStatus == nil)
        let content = try #require(coordinator.permissionContent)
        #expect(content.actions == [.request])
    }
}

// MARK: - Open Settings

@MainActor
struct OpenSettingsTests {
    @Test("Open Settings opens the checker's deep link for the current step", arguments: [
        (OnboardingStep.microphone, TCCCategory.microphone),
        (.systemAudio, .systemAudioCapture),
        (.notifications, .notifications),
    ])
    func opensTheCategoryDeepLink(step: OnboardingStep, category: TCCCategory) async throws {
        let opened = Recorder<URL>()
        let coordinator = makeCoordinator(
            checker: FakePermissionChecker(deepLinks: settingsLinks),
            opener: { url in
                opened.record(url)
                return true
            },
        )
        walk(coordinator, to: step)

        await coordinator.perform(.openSettings)

        #expect(try opened.values == [#require(settingsLinks[category])])
        #expect(coordinator.step == step)
    }

    @Test func nilDeepLinkNeverCallsTheOpener() async {
        let opened = Recorder<URL>()
        let coordinator = makeCoordinator(
            checker: FakePermissionChecker(deepLinks: [:]),
            opener: { url in
                opened.record(url)
                return true
            },
        )
        walk(coordinator, to: .microphone)

        await coordinator.perform(.openSettings)

        #expect(opened.values.isEmpty)
    }

    @Test func offAPermissionStepNeitherOpensNorAdvances() async {
        let opened = Recorder<URL>()
        let coordinator = makeCoordinator(
            checker: FakePermissionChecker(deepLinks: settingsLinks),
            opener: { url in
                opened.record(url)
                return true
            },
        )
        walk(coordinator, to: .configure)

        await coordinator.perform(.openSettings)
        coordinator.continuePastCurrentPermission()

        #expect(opened.values.isEmpty)
        #expect(coordinator.step == .configure)
        #expect(coordinator.permissionContent == nil)
    }
}

// MARK: - System Audio

@MainActor
struct SystemAudioPermissionStepTests {
    @Test func probeRunsOnceAndStepRemainsWithHedgedCopy() async throws {
        let checker = FakePermissionChecker()
        let source = FakeSystemAudioSource()
        let coordinator = makeCoordinator(checker: checker, source: source)
        walk(coordinator, to: .systemAudio)

        await coordinator.perform(.request)

        #expect(source.startCallCount == 1)
        #expect(source.stopCallCount == 1)
        #expect(checker.categoriesRequested.isEmpty)
        #expect(coordinator.step == .systemAudio)
        #expect(coordinator.permissionStatus == .unknown)
        let content = try #require(coordinator.permissionContent)
        #expect(content.followUp == PermissionStepContent.systemAudioHedgeMessage)
        #expect(content.actions == [.openSettings, .continueOnward])
    }

    @Test func probeFailureLogsWarnAndShowsTheSameResult() async throws {
        let checker = FakePermissionChecker()
        let logs = LogRecorder()
        let coordinator = makeCoordinator(checker: checker, source: FakeSystemAudioSource(failOnStart: true), log: logs.log)
        walk(coordinator, to: .systemAudio)

        await coordinator.perform(.request)

        #expect(checker.categoriesRequested.isEmpty)
        #expect(coordinator.step == .systemAudio)
        #expect(coordinator.permissionStatus == .unknown)
        let content = try #require(coordinator.permissionContent)
        #expect(content.followUp == PermissionStepContent.systemAudioHedgeMessage)
        #expect(content.actions == [.openSettings, .continueOnward])
        #expect(logs.records.count == 1)
        #expect(logs.records.first?.level == .default)
        #expect(logs.records.first?.message.hasPrefix("system audio permission probe failed") == true)
    }

    @Test func continueAdvancesToNotifications() async {
        let coordinator = makeCoordinator(checker: FakePermissionChecker())
        walk(coordinator, to: .systemAudio)
        await coordinator.perform(.request)

        await coordinator.perform(.continueOnward)

        #expect(coordinator.step == .notifications)
        #expect(coordinator.permissionStatus == nil)
    }
}

// MARK: - Notifications

@MainActor
struct NotificationsPermissionStepTests {
    @Test func grantedAdvancesToConfigure() async {
        let checker = FakePermissionChecker(requestResult: .granted)
        let coordinator = makeCoordinator(checker: checker)
        walk(coordinator, to: .notifications)

        await coordinator.perform(.request)

        #expect(coordinator.step == .configure)
        #expect(checker.categoriesRequested == [.notifications])
    }

    @Test func deniedRemainsWithSilentNotificationsCopyAndOnlyContinue() async throws {
        let coordinator = makeCoordinator(checker: FakePermissionChecker(requestResult: .denied))
        walk(coordinator, to: .notifications)

        await coordinator.perform(.request)

        #expect(coordinator.step == .notifications)
        let content = try #require(coordinator.permissionContent)
        #expect(content.followUp == PermissionStepContent.notificationsDeniedMessage)
        #expect(content.actions == [.continueOnward])

        await coordinator.perform(.continueOnward)
        #expect(coordinator.step == .configure)
    }
}

// MARK: - Stale request outcome

@MainActor
struct StaleRequestOutcomeTests {
    @Test("An outcome arriving after the step moved on is dropped", arguments: [
        OnboardingPermissionOutcome.advance, .remainWithStatus(.denied),
    ])
    func outcomeAfterSkipIsIgnored(outcome: OnboardingPermissionOutcome) async {
        let gated = GatedPermissionStep()
        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: OnboardingConfigureModel(
                opener: { _ in true },
                validateVaultPath: { _ in },
                writeVaultPath: { _ in },
                writeAPIKey: { _ in },
                configuredVaultPath: { nil },
                writeSelfWikilink: { _ in },
                configuredSelfWikilink: { nil },
                fullUserName: "Jordan Lee",
                vaultTerms: { _ in Glossary() },
            ),
            applicationSupportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            opener: { _ in true },
            permissionSteps: [.microphone: gated],
        )
        walk(coordinator, to: .microphone)

        let request = Task { await coordinator.perform(.request) }
        while !gated.isSuspended {
            await Task.yield()
        }
        await coordinator.perform(.skip)
        gated.release(outcome)
        await request.value

        #expect(coordinator.step == .systemAudio)
        #expect(coordinator.permissionStatus == nil)
    }
}
