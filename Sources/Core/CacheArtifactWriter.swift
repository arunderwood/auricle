import Foundation

/// Cache-dir JSON writes (AR-PIPE-4, architecture.md's Core-primitives
/// table): every stage writes its handoff artifact to
/// `~/Library/Caches/com.auricle.app/<meeting-id>/<name>` through here,
/// never through `AtomicWriter` directly, so every artifact gets the same
/// `schema_version` injection and 0600 permissions without each call site
/// repeating that policy.
public enum CacheArtifactWriter {
    public enum WriteError: Error {
        case cacheRootUnavailable(underlying: Error)
        case directoryCreationFailed(path: String, underlying: Error)
        case encodingFailed(underlying: Error)
        /// `value` encoded to a JSON array or scalar instead of an object,
        /// so there was no top level to inject `schema_version` into.
        case notATopLevelJSONObject
        case permissionsFailed(path: String, underlying: Error)
    }

    /// Encodes `value`, adds a top-level `schema_version` field, and writes
    /// the result to `<cache root>/<id>/<name>` via `AtomicWriter`, then sets
    /// the file to 0600 — cache-dir artifacts carry meeting audio and
    /// transcript content, so they stay owner-only regardless of umask.
    ///
    /// Propagates `AtomicWriter.WriteError` un-wrapped for the write itself;
    /// every other failure here surfaces as `CacheArtifactWriter.WriteError`.
    /// Inherits `AtomicWriter.write`'s "not safe to call concurrently for the
    /// same path" constraint.
    public static func write(
        _ value: some Encodable,
        for id: MeetingID,
        named name: String,
        schemaVersion: Int,
    ) throws {
        let directory = try cacheDirectory(for: id)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WriteError.directoryCreationFailed(path: directory.path, underlying: error)
        }

        let data = try encode(value, schemaVersion: schemaVersion)
        let target = directory.appendingPathComponent(name)
        try AtomicWriter.write(data, to: target)

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        } catch {
            throw WriteError.permissionsFailed(path: target.path, underlying: error)
        }
    }

    /// `~/Library/Caches/com.auricle.app/` — the one place the cache root is
    /// constructed. Not created here: callers that write directly under it
    /// (the vault glossary cache) create it themselves, and
    /// `write(_:for:named:schemaVersion:)` creates the per-meeting directory
    /// beneath it.
    public static func cacheRoot() throws -> URL {
        let caches: URL
        do {
            caches = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true,
            )
        } catch {
            throw WriteError.cacheRootUnavailable(underlying: error)
        }
        return caches.appendingPathComponent("com.auricle.app", isDirectory: true)
    }

    /// `~/Library/Caches/com.auricle.app/<meeting-id>/` — exposed so callers
    /// (and tests) can locate what `write` produced without duplicating this
    /// path construction.
    public static func cacheDirectory(for id: MeetingID) throws -> URL {
        try cacheRoot().appendingPathComponent(id.rawValue, isDirectory: true)
    }

    /// `JSONSerialization` round-trip rather than a custom `Encoder`: a
    /// cache artifact type already declares its own snake_case `CodingKeys`
    /// per the cache-dir JSON dialect (`Codable+Dialects.swift`), so merging
    /// at the parsed-object level adds `schema_version` alongside those keys
    /// without requiring every cache artifact type to reserve a property for
    /// it.
    private static func encode(_ value: some Encodable, schemaVersion: Int) throws -> Data {
        let valueData: Data
        do {
            valueData = try JSONEncoder().encode(value)
        } catch {
            throw WriteError.encodingFailed(underlying: error)
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: valueData)
        } catch {
            throw WriteError.encodingFailed(underlying: error)
        }
        guard var jsonObject = parsed as? [String: Any] else {
            throw WriteError.notATopLevelJSONObject
        }
        jsonObject["schema_version"] = schemaVersion

        do {
            return try JSONSerialization.data(withJSONObject: jsonObject)
        } catch {
            throw WriteError.encodingFailed(underlying: error)
        }
    }
}
