@testable import Core
import Foundation
import Testing

private func makeTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func writeProducesTargetFileWithCorrectContents() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("artifact.json")
    let data = Data("hello".utf8)

    try AtomicWriter.write(data, to: target)

    #expect(FileManager.default.fileExists(atPath: target.path))
    #expect(try Data(contentsOf: target) == data)
    #expect(!FileManager.default.fileExists(atPath: AtomicWriter.temporaryURL(for: target).path))
}

@Test func writeAppliesRequestedPermissionsExactly() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("private.md")

    try AtomicWriter.write(Data("secret".utf8), to: target, permissions: 0o600)

    let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

private struct SimulatedKill: Error {}

/// Runs the real writer and aborts it at the instant a kill would leave a full
/// temp file and an untouched target: after the temp file is closed, before
/// the rename.
@Test func killedBeforeRenameLeavesTheCompleteTempFileAndNoTarget() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("artifact.json")
    let tempURL = AtomicWriter.temporaryURL(for: target)
    let newData = Data("complete".utf8)

    #expect(throws: SimulatedKill.self) {
        try AtomicWriter.perform(newData, to: target, permissions: nil) { throw SimulatedKill() }
    }

    #expect(try Data(contentsOf: tempURL) == newData)
    #expect(!FileManager.default.fileExists(atPath: target.path))

    // The next run's normal write replaces the leftover and cleans it up.
    try AtomicWriter.write(newData, to: target)
    #expect(try Data(contentsOf: target) == newData)
    #expect(!FileManager.default.fileExists(atPath: tempURL.path))
}

@Test func killedBeforeRenameLeavesAnExistingTargetReadingTheOldData() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("artifact.json")
    let tempURL = AtomicWriter.temporaryURL(for: target)
    let oldData = Data("old".utf8)
    let newData = Data("new, and longer than the old contents".utf8)
    try AtomicWriter.write(oldData, to: target)

    #expect(throws: SimulatedKill.self) {
        try AtomicWriter.perform(newData, to: target, permissions: nil) { throw SimulatedKill() }
    }

    #expect(try Data(contentsOf: target) == oldData)
    #expect(try Data(contentsOf: tempURL) == newData)
}

@Test func theHookRunsAfterTheTempFileIsCompleteAndBeforeTheTargetChanges() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("artifact.json")
    let tempURL = AtomicWriter.temporaryURL(for: target)
    try AtomicWriter.write(Data("old".utf8), to: target)

    var observed: (temp: Data, target: Data)?
    try AtomicWriter.perform(Data("new".utf8), to: target, permissions: nil) {
        observed = try (Data(contentsOf: tempURL), Data(contentsOf: target))
    }

    #expect(observed?.temp == Data("new".utf8))
    #expect(observed?.target == Data("old".utf8))
    #expect(try Data(contentsOf: target) == Data("new".utf8))
}

@Test func rerunOverwritesAtomically() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("artifact.json")

    try AtomicWriter.write(Data("first".utf8), to: target)
    try AtomicWriter.write(Data("second".utf8), to: target)

    #expect(try Data(contentsOf: target) == Data("second".utf8))
    #expect(!FileManager.default.fileExists(atPath: AtomicWriter.temporaryURL(for: target).path))
}

@Test func createTemporaryFileFailedWhenParentDirectoryMissing() {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("missing-subdir").appendingPathComponent("artifact.json")

    do {
        try AtomicWriter.write(Data("x".utf8), to: target)
        Issue.record("Expected AtomicWriter.write to throw")
    } catch let AtomicWriter.WriteError.createTemporaryFileFailed(path, errnoValue) {
        #expect(path == AtomicWriter.temporaryURL(for: target).path)
        #expect(errnoValue != 0)
    } catch {
        Issue.record("Expected .createTemporaryFileFailed, got \(error)")
    }
}
