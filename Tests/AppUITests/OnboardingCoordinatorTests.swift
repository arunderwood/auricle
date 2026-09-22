@testable import AppUI
import Foundation
import os
import Permissions
import Persist
import Testing

// MARK: - Test doubles

/// Records every value handed to it under a lock, so a `@Sendable` closure
/// captured by `OnboardingConfigureModel`/`OnboardingCoordinator` can report
/// back without a data race, matching `PermissionCheckedNotificationAuthorizationTests`'s
/// own `FakePermissionChecker` pattern in `Tests/NotificationsTests`.
private final class Recorder<Value: Sendable>: Sendable {
    private let lock = OSAllocatedUnfairLock<[Value]>(initialState: [])

    func record(_ value: Value) {
        lock.withLock { $0.append(value) }
    }

    var values: [Value] {
        lock.withLock { $0 }
    }
}

private final class FakePermissionChecker: PermissionChecking {
    private let requestResult: PermissionStatus
    private let requestedCategories = Recorder<TCCCategory>()

    init(requestResult: PermissionStatus = .granted) {
        self.requestResult = requestResult
    }

    var categoriesRequested: [TCCCategory] {
        requestedCategories.values
    }

    func check(_: TCCCategory) async -> PermissionStatus {
        .notDetermined
    }

    func request(_ category: TCCCategory) async -> PermissionStatus {
        requestedCategories.record(category)
        return requestResult
    }

    func refresh() async {}

    func remediationDeepLink(for _: TCCCategory) -> URL? {
        nil
    }
}

private func makeTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func chmod(_ url: URL, _ permissions: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

@MainActor
private func makeConfigureModel(
    opener: @escaping URLOpener = { _ in true },
    writeVaultPath: @escaping @Sendable (URL) throws -> Void = { _ in },
    writeAPIKey: @escaping @Sendable (String) throws -> Void = { _ in },
) -> OnboardingConfigureModel {
    OnboardingConfigureModel(opener: opener, writeVaultPath: writeVaultPath, writeAPIKey: writeAPIKey)
}

// MARK: - OnboardingMarker

struct OnboardingMarkerTests {
    @Test func absentUntilWritten() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(!OnboardingMarker.exists(applicationSupportDirectory: directory))
        try OnboardingMarker.write(applicationSupportDirectory: directory)
        #expect(OnboardingMarker.exists(applicationSupportDirectory: directory))
    }

    @Test func writeIsIdempotent() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try OnboardingMarker.write(applicationSupportDirectory: directory)
        try OnboardingMarker.write(applicationSupportDirectory: directory)
        #expect(OnboardingMarker.exists(applicationSupportDirectory: directory))
    }
}

// MARK: - OnboardingConfigureModel

@MainActor
struct OnboardingConfigureModelTests {
    @Test func validVaultPathValidatesAndStores() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel()
        try model.selectVaultPath(directory)
        #expect(model.vaultPath == directory)
        #expect(model.vaultPathError == nil)
    }

    @Test func missingVaultPathThrowsAndDoesNotStore() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = makeConfigureModel()

        do {
            try model.selectVaultPath(missing)
            Issue.record("expected selectVaultPath to throw for a nonexistent path")
        } catch let VaultWriter.WriteError.vaultPathMissing(path) {
            #expect(path == missing.path)
        } catch {
            Issue.record("expected .vaultPathMissing, got \(error)")
        }
        #expect(model.vaultPath == nil)
        #expect(model.vaultPathError != nil)
    }

    @Test func notWritableVaultPathThrowsAndDoesNotStore() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try chmod(directory, 0o500)
        defer { try? chmod(directory, 0o700) }

        let model = makeConfigureModel()
        do {
            try model.selectVaultPath(directory)
            Issue.record("expected selectVaultPath to throw for a read-only path")
        } catch let VaultWriter.WriteError.vaultPathNotWritable(path) {
            #expect(path == directory.path)
        } catch {
            Issue.record("expected .vaultPathNotWritable, got \(error)")
        }
        #expect(model.vaultPath == nil)
    }

    @Test func obsidianOpenerTrueDoesNotShowInstallMessage() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel(opener: { _ in true })
        try model.selectVaultPath(directory)
        await model.checkObsidian()
        #expect(model.obsidianOpened == true)
    }

    @Test func obsidianOpenerFalseDoesNotBlock() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel(opener: { _ in false })
        try model.selectVaultPath(directory)
        await model.checkObsidian()
        #expect(model.obsidianOpened == false)
    }

    @Test func checkObsidianOpensTheVaultURLForTheSelectedPath() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let openedURLs = Recorder<URL>()
        let model = makeConfigureModel(opener: { url in
            openedURLs.record(url)
            return true
        })
        try model.selectVaultPath(directory)
        await model.checkObsidian()

        let expectedURL = try #require(URL(string: "obsidian://open?vault=\(directory.lastPathComponent)"))
        #expect(openedURLs.values == [expectedURL])
    }

    @Test func skippingAPIKeyNeverWritesToKeychain() {
        let recorder = Recorder<String>()
        _ = makeConfigureModel(writeAPIKey: { recorder.record($0) })
        // The skip path is simply never calling `setAPIKey`.
        #expect(recorder.values.isEmpty)
    }

    @Test func providingAPIKeyWrites() throws {
        let recorder = Recorder<String>()
        let model = makeConfigureModel(writeAPIKey: { recorder.record($0) })
        try model.setAPIKey("sk-ant-test")
        #expect(recorder.values == ["sk-ant-test"])
    }

    @Test func finishWritesTheValidatedVaultPathExactlyOnce() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder<URL>()
        let model = makeConfigureModel(writeVaultPath: { recorder.record($0) })
        try model.selectVaultPath(directory)
        try model.finish()
        #expect(recorder.values == [directory])
    }

    @Test func finishWithoutAVaultPathThrows() {
        let model = makeConfigureModel()
        do {
            try model.finish()
            Issue.record("expected finish() to throw without a validated vault path")
        } catch OnboardingConfigureModel.FinishError.vaultPathNotSelected {
            // expected
        } catch {
            Issue.record("expected .vaultPathNotSelected, got \(error)")
        }
    }
}

// MARK: - OnboardingCoordinator

@MainActor
struct OnboardingCoordinatorTests {
    @Test func startsAtWelcome() {
        let coordinator = OnboardingCoordinator(checker: FakePermissionChecker(), configure: makeConfigureModel())
        #expect(coordinator.step == .welcome)
    }

    @Test func advanceWalksEveryStepInOrder() async {
        let checker = FakePermissionChecker()
        let coordinator = OnboardingCoordinator(checker: checker, configure: makeConfigureModel())

        #expect(coordinator.step == .welcome)
        coordinator.advance()
        #expect(coordinator.step == .microphone)
        await coordinator.requestCurrentPermission()
        #expect(coordinator.step == .systemAudio)
        await coordinator.requestCurrentPermission()
        #expect(coordinator.step == .notifications)
        await coordinator.requestCurrentPermission()
        #expect(coordinator.step == .configure)
        coordinator.advance()
        #expect(coordinator.step == .done)
    }

    @Test func advanceIsANoOpOnceDone() {
        let coordinator = OnboardingCoordinator(checker: FakePermissionChecker(), configure: makeConfigureModel())
        for _ in OnboardingStep.allCases {
            coordinator.advance()
        }
        #expect(coordinator.step == .done)
        coordinator.advance()
        #expect(coordinator.step == .done)
    }

    @Test("Default permission step advances regardless of status", arguments: [
        PermissionStatus.granted, .denied, .notDetermined, .unknown,
    ])
    func defaultPermissionStepAlwaysAdvances(status: PermissionStatus) async {
        let checker = FakePermissionChecker(requestResult: status)
        let coordinator = OnboardingCoordinator(checker: checker, configure: makeConfigureModel())
        coordinator.advance() // welcome -> microphone

        await coordinator.requestCurrentPermission()

        #expect(coordinator.step == .systemAudio)
        #expect(checker.categoriesRequested == [.microphone])
    }

    @Test func requestCurrentPermissionIsANoOpOffAPermissionStep() async {
        let checker = FakePermissionChecker()
        let coordinator = OnboardingCoordinator(checker: checker, configure: makeConfigureModel())

        await coordinator.requestCurrentPermission() // step is .welcome

        #expect(coordinator.step == .welcome)
        #expect(checker.categoriesRequested.isEmpty)
    }

    @Test func completeOnboardingWritesMarkerAndVaultPathExactlyOnce() throws {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let vaultDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: vaultDirectory) }

        let vaultPathWrites = Recorder<URL>()
        let configure = makeConfigureModel(writeVaultPath: { vaultPathWrites.record($0) })
        try configure.selectVaultPath(vaultDirectory)

        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: configure,
            applicationSupportDirectory: applicationSupportDirectory,
        )

        #expect(!OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory))
        try coordinator.completeOnboarding()
        #expect(OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory))
        #expect(vaultPathWrites.values == [vaultDirectory])
    }

    @Test func completeOnboardingPropagatesAMissingVaultPath() {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }

        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: makeConfigureModel(),
            applicationSupportDirectory: applicationSupportDirectory,
        )

        #expect(throws: OnboardingConfigureModel.FinishError.self) {
            try coordinator.completeOnboarding()
        }
        #expect(!OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory))
    }
}
