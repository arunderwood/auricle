import Core
import Foundation

/// What a vault looked like when its glossary was built: the newest
/// modification date and the number of entries over every file and directory
/// the scan does not skip. A file edited in place changes no directory's date,
/// so the files count too; an added or removed entry changes the count even
/// when a clock or a restore leaves every date alone.
struct VaultFingerprint: Codable, Equatable {
    /// Seconds since 1970; `nil` for a vault with no entries at all.
    let newestModification: Double?
    let entryCount: Int

    enum CodingKeys: String, CodingKey {
        case newestModification = "newest_modification"
        case entryCount = "entry_count"
    }
}

/// `<cache root>/glossary-cache.json` (cache-artifact dialect): the last built
/// glossary with the vault path and fingerprint it was built from. A cache that
/// cannot be read back is the same as no cache, never an error.
struct GlossaryCache: Codable, Equatable {
    static let fileName = "glossary-cache.json"
    static let schemaVersion = 1

    let schemaVersion: Int
    let vaultPath: String
    let fingerprint: VaultFingerprint
    let glossary: Glossary

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case vaultPath = "vault_path"
        case fingerprint
        case glossary
    }

    init(vaultPath: String, fingerprint: VaultFingerprint, glossary: Glossary) {
        schemaVersion = Self.schemaVersion
        self.vaultPath = vaultPath
        self.fingerprint = fingerprint
        self.glossary = glossary
    }

    /// The cache at `root`, when it decodes, carries the current schema
    /// version, and was built for `vaultPath` at `fingerprint`.
    static func fresh(in root: URL, vaultPath: String, fingerprint: VaultFingerprint) -> GlossaryCache? {
        guard
            let data = try? Data(contentsOf: root.appendingPathComponent(fileName)),
            let cache = try? JSONDecoder().decode(GlossaryCache.self, from: data),
            cache.schemaVersion == schemaVersion,
            cache.vaultPath == vaultPath,
            cache.fingerprint == fingerprint
        else {
            return nil
        }
        return cache
    }

    /// Owner-only, like every cache artifact: the terms come from private
    /// notes. A failure is swallowed, because a cache that cannot be written
    /// only costs the next run a rescan.
    func store(in root: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        let target = root.appendingPathComponent(Self.fileName)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try AtomicWriter.write(data, to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            return
        }
    }
}
