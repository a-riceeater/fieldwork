import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// File-system save/open for platforms without NSDocument (Windows, CLI,
/// tests). The Mac app routes saving through NSDocument and uses only
/// `DocumentCodec`, so exactly one writer ever replaces a document.
public enum DocumentFile {
    public static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".previous")
    }

    /// Reads a document. Never writes to `url`.
    public static func open(_ url: URL) throws -> ShowDocument {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw DocumentError.io("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try DocumentCodec.decode(data)
    }

    /// Encodes, verifies the encoded bytes by decoding them, writes a sibling
    /// temporary file, flushes it and atomically replaces the target, keeping
    /// the prior version as `<name>.previous`.
    public static func save(_ document: ShowDocument, to url: URL) throws {
        let data = try DocumentCodec.encode(document)
        do { _ = try DocumentCodec.decode(data) } catch {
            throw DocumentError.io("Save was cancelled because the new file failed verification: \(error). The existing file was not changed.")
        }
        let directory = url.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            FileManager.default.createFile(atPath: temp.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw DocumentError.io("Could not write to \(directory.lastPathComponent): \(error.localizedDescription). The existing file was not changed.")
        }
        do {
            try replace(url, with: temp, backup: backupURL(for: url))
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw DocumentError.io("Could not replace \(url.lastPathComponent): \(error). The existing file was not changed.")
        }
    }

    struct ReplaceError: Error, CustomStringConvertible {
        var description: String
    }

    static func replace(_ target: URL, with replacement: URL, backup: URL) throws {
        let exists = FileManager.default.fileExists(atPath: target.path)
        #if os(Windows)
        try target.withUnsafeFileSystemRepresentation { targetPath in
            try replacement.withUnsafeFileSystemRepresentation { replacementPath in
                try backup.withUnsafeFileSystemRepresentation { backupPath in
                    let t = String(cString: targetPath!), r = String(cString: replacementPath!), b = String(cString: backupPath!)
                    let ok: Bool = t.withCString(encodedAs: UTF16.self) { tw in
                        r.withCString(encodedAs: UTF16.self) { rw in
                            b.withCString(encodedAs: UTF16.self) { bw in
                                if exists {
                                    _ = DeleteFileW(bw)
                                    return ReplaceFileW(tw, rw, bw, DWORD(REPLACEFILE_IGNORE_MERGE_ERRORS), nil, nil)
                                }
                                return MoveFileExW(rw, tw, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                            }
                        }
                    }
                    if !ok { throw ReplaceError(description: "Windows error \(GetLastError())") }
                }
            }
        }
        #else
        if exists {
            // Hard-link the current file as the backup (target stays intact), then rename atomically.
            _ = unlink(backup.path)
            if link(target.path, backup.path) != 0 {
                try? FileManager.default.copyItem(at: target, to: backup)
            }
        }
        guard rename(replacement.path, target.path) == 0 else { throw ReplaceError(description: "rename failed (errno \(errno))") }
        #endif
    }
}
