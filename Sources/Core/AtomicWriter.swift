import Foundation

/// The sole filesystem-write primitive (NFR-R1 + FR36): every write in the
/// app goes through here so a crash or kill mid-write can never leave a
/// partially-written target file on disk.
public enum AtomicWriter {
    /// Failure at any step of the write-temp / fsync / rename sequence.
    public enum WriteError: Error {
        case createTemporaryFileFailed(path: String, errno: Int32)
        case openTemporaryFileFailed(path: String, underlying: Error)
        case permissionsFailed(path: String, underlying: Error)
        case writeFailed(path: String, underlying: Error)
        case syncFailed(path: String, underlying: Error)
        case closeFailed(path: String, underlying: Error)
        case renameFailed(from: String, to: String, errno: Int32)
    }

    /// Writes `data` to `path` by writing a sibling temp file, syncing it to
    /// disk, then renaming it into place. `rename(2)` between two paths on
    /// the same volume is atomic, so any process observing `path` sees
    /// either the previous contents or the complete new contents — never a
    /// partial write. If interrupted before the rename, the temp file is
    /// left behind at `temporaryURL(for: path)` for the next run to find.
    ///
    /// Not safe to call concurrently for the same `path`: the temp file path
    /// is deterministic, so two overlapping calls targeting the same `path`
    /// share one temp file and race on it — the second call's write can
    /// truncate the first call's in-flight data. Callers are responsible for
    /// serializing writes to a given path.
    ///
    /// `permissions`, when given, is applied to the temp file while it is
    /// still empty, so the renamed target never exists with looser access
    /// than requested. It is an exact mode, not subject to the umask. When
    /// `nil` the file keeps the umask-derived default.
    public static func write(_ data: Data, to path: URL, permissions: Int? = nil) throws {
        let tempURL = temporaryURL(for: path)

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw WriteError.createTemporaryFileFailed(path: tempURL.path, errno: errno)
        }

        if let permissions {
            do {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
            } catch {
                throw WriteError.permissionsFailed(path: tempURL.path, underlying: error)
            }
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: tempURL)
        } catch {
            throw WriteError.openTemporaryFileFailed(path: tempURL.path, underlying: error)
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            throw WriteError.writeFailed(path: tempURL.path, underlying: error)
        }

        do {
            try handle.synchronize()
        } catch {
            try? handle.close()
            throw WriteError.syncFailed(path: tempURL.path, underlying: error)
        }

        do {
            try handle.close()
        } catch {
            throw WriteError.closeFailed(path: tempURL.path, underlying: error)
        }

        guard rename(tempURL.path, path.path) == 0 else {
            throw WriteError.renameFailed(from: tempURL.path, to: path.path, errno: errno)
        }
    }

    /// The sibling temp path a given target resolves to. Deterministic (not
    /// randomized) so a caller — or a test simulating a kill before rename —
    /// can find a write that was interrupted mid-flight.
    public static func temporaryURL(for path: URL) -> URL {
        path.deletingLastPathComponent().appendingPathComponent(".\(path.lastPathComponent).tmp")
    }
}
