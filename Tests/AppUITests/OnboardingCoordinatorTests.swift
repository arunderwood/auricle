@testable import AppUI
import Core
import Foundation
import os
import Permissions
import Testing
import TestSupport

// MARK: - Test doubles

/// Records every value handed to it under a lock, so a `@Sendable` closure
/// captured by `OnboardingConfigureModel`/`OnboardingCoordinator` can report
/// back without a data race.
private final class Recorder<Value: Sendable>: Sendable {
    private let lock = OSAllocatedUnfairLock<[Value]>(initialState: [])

    func record(_ value: Value) {
        lock.withLock { $0.append(value) }
    }

    var values: [Value] {
        lock.withLock { $0 }
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

/// Mirrors `VaultWriter.validateVaultPath`'s own exists+writable check
/// without depending on `Persist` from this test target — `AppUI` doesn't
/// depend on it either, so the model is exercised exactly as `AuricleApp`
/// wires it, translating into the same `VaultPathValidationError` cases.
private func validateVaultPath(_ url: URL) throws {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    guard exists, isDirectory.boolValue else {
        throw VaultPathValidationError.missing(path: url.path)
    }
    guard FileManager.default.isWritableFile(atPath: url.path) else {
        throw VaultPathValidationError.notWritable(path: url.path)
    }
}

/// Walks a freshly-made model from `.vaultPath` to `.apiKey`, so tests that
/// only care about the API key sub-step don't have to restate every prior
/// step's setup.
@MainActor
private func advanceToAPIKeySubStep(_ model: OnboardingConfigureModel, vaultDirectory: URL) throws {
    try model.selectVaultPath(vaultDirectory)
    try model.confirmSelfWikilink()
    model.continueFromObsidian()
}

@MainActor
private func makeConfigureModel(
    opener: @escaping URLOpener = { _ in true },
    validateVaultPath: @escaping @Sendable (URL) throws -> Void = validateVaultPath,
    writeVaultPath: @escaping @Sendable (URL) throws -> Void = { _ in },
    writeAPIKey: @escaping @Sendable (String) throws -> Void = { _ in },
    configuredVaultPath: @escaping @Sendable () -> URL? = { nil },
    writeSelfWikilink: @escaping @Sendable (String) throws -> Void = { _ in },
) -> OnboardingConfigureModel {
    OnboardingConfigureModel(
        opener: opener,
        validateVaultPath: validateVaultPath,
        writeVaultPath: writeVaultPath,
        writeAPIKey: writeAPIKey,
        configuredVaultPath: configuredVaultPath,
        writeSelfWikilink: writeSelfWikilink,
        configuredSelfWikilink: { nil },
        fullUserName: "Jordan Lee",
        vaultTerms: { _ in Glossary() },
    )
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
    @Test func validVaultPathValidatesStoresAndAdvances() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel()
        try model.selectVaultPath(directory)
        #expect(model.vaultPath == directory)
        #expect(model.vaultPathError == nil)
        #expect(model.subStep == .selfWikilink)
    }

    @Test func missingVaultPathThrowsAndDoesNotStoreOrAdvance() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = makeConfigureModel()

        #expect(throws: VaultPathValidationError.missing(path: missing.path)) {
            try model.selectVaultPath(missing)
        }
        #expect(model.vaultPath == nil)
        #expect(model.vaultPathError == .missing(path: missing.path))
        #expect(model.subStep == .vaultPath)
    }

    @Test func notWritableVaultPathThrowsAndDoesNotStoreOrAdvance() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try chmod(directory, 0o500)
        defer { try? chmod(directory, 0o700) }

        let model = makeConfigureModel()
        #expect(throws: VaultPathValidationError.notWritable(path: directory.path)) {
            try model.selectVaultPath(directory)
        }
        #expect(model.vaultPath == nil)
        #expect(model.subStep == .vaultPath)
    }

    @Test func defaultVaultDirectoryFallsBackToSecondBrainWhenNoneConfigured() {
        let model = makeConfigureModel(configuredVaultPath: { nil })
        let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("checkouts/SecondBrain", isDirectory: true)
        #expect(model.defaultVaultDirectory == expected)
    }

    @Test func defaultVaultDirectoryPrefersTheConfiguredVaultPath() {
        let configured = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: configured) }

        let model = makeConfigureModel(configuredVaultPath: { configured })
        #expect(model.defaultVaultDirectory == configured)
    }

    @Test func confirmingTheSelfWikilinkMovesToObsidian() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel()
        try model.selectVaultPath(directory)
        #expect(model.subStep == .selfWikilink)

        try model.confirmSelfWikilink()
        #expect(model.subStep == .obsidian)
    }

    @Test func obsidianOpenerTrueDoesNotShowInstallMessage() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel(opener: { _ in true })
        try model.selectVaultPath(directory)
        try model.confirmSelfWikilink()
        await model.checkObsidian()
        #expect(model.obsidianOpened == true)
    }

    @Test func obsidianOpenerFalseDoesNotBlock() async throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel(opener: { _ in false })
        try model.selectVaultPath(directory)
        try model.confirmSelfWikilink()
        await model.checkObsidian()
        #expect(model.obsidianOpened == false)

        model.continueFromObsidian()
        #expect(model.subStep == .apiKey)
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
        try model.confirmSelfWikilink()
        await model.checkObsidian()

        let expectedURL = try #require(URL(string: "obsidian://open?vault=\(directory.lastPathComponent)"))
        #expect(openedURLs.values == [expectedURL])
    }

    @Test func skippingAPIKeyNeverWritesToKeychainAndAdvances() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder<String>()
        let model = makeConfigureModel(writeAPIKey: { recorder.record($0) })
        try advanceToAPIKeySubStep(model, vaultDirectory: directory)

        model.skipAPIKey()

        #expect(recorder.values.isEmpty)
        #expect(model.subStep == .expectations)
    }

    @Test func providingAPIKeyWritesAndAdvances() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder<String>()
        let model = makeConfigureModel(writeAPIKey: { recorder.record($0) })
        try advanceToAPIKeySubStep(model, vaultDirectory: directory)

        try model.setAPIKey("sk-ant-test")
        #expect(recorder.values == ["sk-ant-test"])
        #expect(model.subStep == .expectations)
    }

    @Test func providingAPIKeyTrimsSurroundingWhitespaceBeforeWriting() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let recorder = Recorder<String>()
        let model = makeConfigureModel(writeAPIKey: { recorder.record($0) })
        try advanceToAPIKeySubStep(model, vaultDirectory: directory)
        try model.setAPIKey("  sk-ant-test\n")
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

    @Test func finishWritesTheConfirmedSelfWikilinkAfterTheVaultPath() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writes = Recorder<String>()
        let model = makeConfigureModel(
            writeVaultPath: { writes.record("vault_path=\($0.path)") },
            writeSelfWikilink: { writes.record("self.wikilink=\($0)") },
        )
        try model.selectVaultPath(directory)
        model.selfWikilinkText = "Jordan"
        try model.confirmSelfWikilink()
        try model.finish()
        #expect(writes.values == ["vault_path=\(directory.path)", "self.wikilink=[[Jordan]]"])
    }

    @Test func finishWithoutAConfirmedSelfWikilinkWritesOnlyTheVaultPath() throws {
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let selfWikilinkWrites = Recorder<String>()
        let model = makeConfigureModel(writeSelfWikilink: { selfWikilinkWrites.record($0) })
        try model.selectVaultPath(directory)
        try model.finish()
        #expect(selfWikilinkWrites.values.isEmpty)
    }

    @Test func finishPropagatesASelfWikilinkWriteError() throws {
        struct WriteFailed: Error {}
        let directory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = makeConfigureModel(writeSelfWikilink: { _ in throw WriteFailed() })
        try model.selectVaultPath(directory)
        try model.confirmSelfWikilink()
        #expect(throws: WriteFailed.self) {
            try model.finish()
        }
    }

    @Test func finishWithoutAVaultPathThrows() {
        let model = makeConfigureModel()
        #expect(throws: OnboardingConfigureModel.FinishError.vaultPathNotSelected) {
            try model.finish()
        }
    }
}

// MARK: - OnboardingCoordinator

@MainActor
struct OnboardingCoordinatorTests {
    @Test func startsAtWelcome() {
        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: makeConfigureModel(),
            applicationSupportDirectory: makeTestDirectory(),
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )
        #expect(coordinator.step == .welcome)
    }

    @Test func advanceWalksEveryStepInOrder() async {
        let checker = FakePermissionChecker()
        let coordinator = OnboardingCoordinator(
            checker: checker,
            configure: makeConfigureModel(),
            applicationSupportDirectory: makeTestDirectory(),
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )

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
        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: makeConfigureModel(),
            applicationSupportDirectory: makeTestDirectory(),
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )
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
        let coordinator = OnboardingCoordinator(
            checker: checker,
            configure: makeConfigureModel(),
            applicationSupportDirectory: makeTestDirectory(),
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )
        coordinator.advance() // welcome -> microphone

        await coordinator.requestCurrentPermission()

        #expect(coordinator.step == .systemAudio)
        #expect(checker.categoriesRequested == [.microphone])
    }

    @Test func requestCurrentPermissionIsANoOpOffAPermissionStep() async {
        let checker = FakePermissionChecker()
        let coordinator = OnboardingCoordinator(
            checker: checker,
            configure: makeConfigureModel(),
            applicationSupportDirectory: makeTestDirectory(),
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )

        await coordinator.requestCurrentPermission() // step is .welcome

        #expect(coordinator.step == .welcome)
        #expect(checker.categoriesRequested.isEmpty)
    }

    @Test func completeOnboardingWritesMarkerVaultPathAndSelfWikilinkExactlyOnce() throws {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let vaultDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: vaultDirectory) }

        let vaultPathWrites = Recorder<URL>()
        let selfWikilinkWrites = Recorder<String>()
        let configure = makeConfigureModel(
            writeVaultPath: { vaultPathWrites.record($0) },
            writeSelfWikilink: { selfWikilinkWrites.record($0) },
        )
        try configure.selectVaultPath(vaultDirectory)
        try configure.confirmSelfWikilink()

        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: configure,
            applicationSupportDirectory: applicationSupportDirectory,
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )

        #expect(!OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory))
        try coordinator.completeOnboarding()
        #expect(OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory))
        #expect(vaultPathWrites.values == [vaultDirectory])
        #expect(selfWikilinkWrites.values == ["[[Jordan Lee]]"])
    }

    @Test func completeOnboardingPropagatesAMissingVaultPath() {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }

        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: makeConfigureModel(),
            applicationSupportDirectory: applicationSupportDirectory,
            progress: OnboardingProgress(isComplete: false),
            opener: { _ in true },
        )

        #expect(throws: OnboardingConfigureModel.FinishError.self) {
            try coordinator.completeOnboarding()
        }
        #expect(!OnboardingMarker.exists(applicationSupportDirectory: applicationSupportDirectory))
    }

    @Test func enterAppAfterCompletingOnboardingMarksProgressComplete() throws {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let vaultDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: vaultDirectory) }
        let configure = makeConfigureModel()
        try configure.selectVaultPath(vaultDirectory)
        let progress = OnboardingProgress(isComplete: false)
        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: configure,
            applicationSupportDirectory: applicationSupportDirectory,
            progress: progress,
            opener: { _ in true },
        )

        try coordinator.completeOnboarding()
        #expect(!progress.isComplete)
        coordinator.enterApp()

        #expect(progress.isComplete)
    }

    @Test func enterAppBeforeOnboardingCompletedLeavesProgressIncomplete() {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }
        let progress = OnboardingProgress(isComplete: false)
        let coordinator = OnboardingCoordinator(
            checker: FakePermissionChecker(),
            configure: makeConfigureModel(),
            applicationSupportDirectory: applicationSupportDirectory,
            progress: progress,
            opener: { _ in true },
        )

        coordinator.enterApp()
        #expect(throws: OnboardingConfigureModel.FinishError.self) {
            try coordinator.completeOnboarding()
        }
        coordinator.enterApp()

        #expect(!progress.isComplete)
    }

    @Test func progressReadsTheMarkerOnce() throws {
        let applicationSupportDirectory = makeTestDirectory()
        defer { try? FileManager.default.removeItem(at: applicationSupportDirectory) }

        #expect(!OnboardingProgress(applicationSupportDirectory: applicationSupportDirectory).isComplete)
        try OnboardingMarker.write(applicationSupportDirectory: applicationSupportDirectory)
        #expect(OnboardingProgress(applicationSupportDirectory: applicationSupportDirectory).isComplete)
    }
}
