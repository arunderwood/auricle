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

@Test func killedBeforeRenameLeavesTempFileAndNoPartialTarget() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appendingPathComponent("artifact.json")
    let tempURL = AtomicWriter.temporaryURL(for: target)

    // Simulates a kill after the temp write but before the rename: perform
    // only the first phase of AtomicWriter.write's sequence by writing
    // directly to the well-known temp path, without renaming.
    try Data("partial".utf8).write(to: tempURL)

    #expect(FileManager.default.fileExists(atPath: tempURL.path))
    #expect(!FileManager.default.fileExists(atPath: target.path))

    // The caller's next run retries with a normal write, which succeeds and
    // cleans up the leftover temp file.
    let finalData = Data("complete".utf8)
    try AtomicWriter.write(finalData, to: target)

    #expect(try Data(contentsOf: target) == finalData)
    #expect(!FileManager.default.fileExists(atPath: tempURL.path))
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
