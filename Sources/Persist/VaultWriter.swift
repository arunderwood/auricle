import Core
import Foundation

/// Publishes rendered markdown into the user's Obsidian vault: validates
/// `vaultPath`, resolves and (if needed) auto-creates `meetingsSubdir`,
/// resolves a collision-free filename via `FilenameResolver`, then delegates
/// the actual write to `AtomicWriter` — never a direct filesystem call —
/// per AR-PAT-4 helper discipline.
public enum VaultWriter {
    public enum WriteError: Error {
        case vaultPathMissing(path: String)
        case vaultPathNotWritable(path: String)
        case meetingsSubdirIsNotADirectory(path: String)
        case meetingsSubdirNotWritable(path: String)
        case meetingsSubdirCreationFailed(path: String, underlying: Error)
        /// `path` is the *last* candidate tried (i.e. the one at
        /// `maxOrdinal`), not a next-attempted or otherwise special path.
        case collisionRetriesExhausted(path: String, maxOrdinal: Int)
    }

    /// A high, effectively-never-hit ceiling — same-day, same-slug
    /// collisions this deep are not a realistic scenario; this cap exists so
    /// a `FilenameResolver` defect or data-corruption scenario fails fast
    /// with a clear error instead of spinning forever, matching every other
    /// failure mode in this function. Deliberately not `private`: a test
    /// asserting `.collisionRetriesExhausted` behavior needs to reference
    /// this exact value via `@testable import` rather than hardcoding a
    /// duplicate literal that could silently drift from the real cap.
    static let maxCollisionOrdinal = 1000

    /// Throws `VaultWriter.WriteError` for a validation/collision failure,
    /// or propagates `AtomicWriter.WriteError` from the underlying write.
    /// Inherits `AtomicWriter.write`'s "not safe to call concurrently for
    /// the same path" constraint — `VaultWriter` adds no serialization of
    /// its own on top.
    public static func write(
        _ markdown: String,
        meeting: MeetingForFilename,
        vaultPath: URL,
        meetingsSubdir: String,
    ) throws -> URL {
        try validateVaultPath(vaultPath)
        let subdirURL = try resolveMeetingsSubdir(vaultPath: vaultPath, meetingsSubdir: meetingsSubdir)
        let targetURL = try collisionFreeTarget(meeting: meeting, in: subdirURL)
        try AtomicWriter.write(Data(markdown.utf8), to: targetURL)
        return targetURL
    }

    /// Writes `markdown` to an already-resolved, already-validated exact
    /// target: no `vaultPath`/`meetingsSubdir` validation, no collision
    /// detection. For a caller that has already picked the exact file it
    /// wants written — e.g. `PersistStage`'s own rerun-filename construction
    /// (Decision 2.4: rerun-suffix generation is a different axis than
    /// `FilenameResolver`'s ordinal and belongs to the persist stage, not
    /// here) — so persist never reaches past `VaultWriter` to call
    /// `AtomicWriter` directly.
    public static func writeExact(_ markdown: String, to url: URL) throws {
        try AtomicWriter.write(Data(markdown.utf8), to: url)
    }

    // MARK: - vaultPath validation

    /// "Exists as a directory" is the actual requirement — a `vaultPath`
    /// that exists but is a plain file throws the same `.vaultPathMissing`
    /// as a fully-missing path, per Decision 2.5. Never auto-created here or
    /// anywhere else in this function.
    private static func validateVaultPath(_ vaultPath: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: vaultPath.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw WriteError.vaultPathMissing(path: vaultPath.path)
        }
        guard FileManager.default.isWritableFile(atPath: vaultPath.path) else {
            throw WriteError.vaultPathNotWritable(path: vaultPath.path)
        }
    }

    // MARK: - meetingsSubdir resolution

    /// `meetingsSubdir` may itself be a nested relative path (Decision 2.5's
    /// own rationale text gives `inbox/Meetings/` as an example, alongside a
    /// flat `auricle/`), so auto-creation uses `withIntermediateDirectories:
    /// true` to create every missing component under it. Auricle owns this
    /// one subdirectory, so auto-creating it is safe — unlike `vaultPath`,
    /// which this function never creates.
    private static func resolveMeetingsSubdir(vaultPath: URL, meetingsSubdir: String) throws -> URL {
        let subdirURL = vaultPath.appendingPathComponent(meetingsSubdir)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: subdirURL.path, isDirectory: &isDirectory)

        guard exists else {
            do {
                try FileManager.default.createDirectory(
                    at: subdirURL,
                    withIntermediateDirectories: true,
                    attributes: inheritedPermissions(from: vaultPath),
                )
            } catch {
                throw WriteError.meetingsSubdirCreationFailed(path: subdirURL.path, underlying: error)
            }
            return subdirURL
        }

        guard isDirectory.boolValue else {
            throw WriteError.meetingsSubdirIsNotADirectory(path: subdirURL.path)
        }
        guard FileManager.default.isWritableFile(atPath: subdirURL.path) else {
            throw WriteError.meetingsSubdirNotWritable(path: subdirURL.path)
        }
        return subdirURL
    }

    /// `try?` swallows a permissions-read failure as a reasonable defensive
    /// default — `createDirectory` still succeeds with umask-derived
    /// permissions in that case, just without inheriting `vaultPath`'s own.
    private static func inheritedPermissions(from vaultPath: URL) -> [FileAttributeKey: Any]? {
        guard let permissions = try? FileManager.default.attributesOfItem(atPath: vaultPath.path)[.posixPermissions] else {
            return nil
        }
        return [.posixPermissions: permissions]
    }

    // MARK: - Collision-free filename resolution

    /// Deterministic (never random) ordinal counter per Decision 2.4: tries
    /// the bare filename first, then `-2`, `-3`, ... until an unused path is
    /// found, capped at `maxCollisionOrdinal` so a `FilenameResolver` defect
    /// or genuine data-corruption scenario fails fast rather than looping
    /// indefinitely.
    private static func collisionFreeTarget(meeting: MeetingForFilename, in subdirURL: URL) throws -> URL {
        var ordinal: Int?
        while true {
            let filename = FilenameResolver.resolve(meeting: meeting, ordinal: ordinal)
            let candidateURL = subdirURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: candidateURL.path) else {
                return candidateURL
            }
            let nextOrdinal = (ordinal ?? 1) + 1
            guard nextOrdinal <= maxCollisionOrdinal else {
                throw WriteError.collisionRetriesExhausted(path: candidateURL.path, maxOrdinal: maxCollisionOrdinal)
            }
            ordinal = nextOrdinal
        }
    }
}
