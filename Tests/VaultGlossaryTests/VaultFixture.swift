import Foundation
import Testing
import VaultGlossary

/// A throwaway vault and cache root under the system temp directory. Each
/// fixture has its own UUID-named base, so `cleanUp()` removes only its own
/// files.
struct VaultFixture {
    let base: URL

    var vault: URL {
        base.appendingPathComponent("vault", isDirectory: true)
    }

    var cacheRoot: URL {
        base.appendingPathComponent("cache", isDirectory: true)
    }

    var cacheFile: URL {
        cacheRoot.appendingPathComponent("glossary-cache.json")
    }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("auricle-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("vault", isDirectory: true), withIntermediateDirectories: true)
    }

    func builder(meetingsSubdir: String = "Meetings") -> VaultGlossaryBuilder {
        VaultGlossaryBuilder(vaultPath: vault, meetingsSubdir: meetingsSubdir, cacheRoot: cacheRoot)
    }

    /// Writes `text` at `url`, creating any missing parent directories.
    func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: false, encoding: .utf8)
    }

    func overwrite(_ url: URL, with data: Data) throws {
        try data.write(to: url)
    }

    func note(_ relativePath: String, _ text: String = "") throws {
        try writeFile(text, to: vault.appendingPathComponent(relativePath))
    }

    /// `""` names the vault directory itself.
    private func url(of relativePath: String) -> URL {
        relativePath.isEmpty ? vault : vault.appendingPathComponent(relativePath)
    }

    func modificationDate(of relativePath: String) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url(of: relativePath).path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    func setModificationDate(_ date: Date, of relativePath: String) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(of: relativePath).path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: base)
    }
}
