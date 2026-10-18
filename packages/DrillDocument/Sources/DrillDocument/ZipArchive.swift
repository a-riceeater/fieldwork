import Foundation

public struct ZipError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Minimal original ZIP implementation for the `.fieldwork` container.
/// Version 1 writers store members uncompressed (method 0) with CRC-32;
/// the reader rejects anything it cannot verify.
public enum ZipArchive {
    public struct Limits: Sendable {
        public var maxMembers = 10_000
        public var maxTotalBytes: Int64 = 2 * 1024 * 1024 * 1024
        public init() {}
    }

    // MARK: Writing

    public static func write(_ members: [(path: String, data: Data)]) throws -> Data {
        var out = Data()
        var central = Data()
        for (path, data) in members {
            try validate(path: path)
            guard data.count < Int(UInt32.max) else { throw ZipError("Member \(path) is too large for this format version.") }
            let name = Data(path.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            out.append(le32: 0x0403_4b50)
            out.append(le16: 20)          // version needed
            out.append(le16: 0x0800)      // UTF-8 names
            out.append(le16: 0)           // stored
            out.append(le16: 0)           // time (fixed for reproducible archives)
            out.append(le16: 0x0021)      // date 1980-01-01
            out.append(le32: crc)
            out.append(le32: UInt32(data.count))
            out.append(le32: UInt32(data.count))
            out.append(le16: UInt16(name.count))
            out.append(le16: 0)
            out.append(name)
            out.append(data)

            central.append(le32: 0x0201_4b50)
            central.append(le16: 20)
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0x0021)
            central.append(le32: crc)
            central.append(le32: UInt32(data.count))
            central.append(le32: UInt32(data.count))
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le16: 0)
            central.append(le32: 0)
            central.append(le32: offset)
            central.append(name)
            guard out.count < Int(UInt32.max) else { throw ZipError("The document is too large for this format version.") }
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        out.append(le32: 0x0605_4b50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(members.count))
        out.append(le16: UInt16(members.count))
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    // MARK: Reading

    /// Reads and verifies every member. Rejects path traversal, encryption,
    /// compression methods other than stored, CRC mismatches and oversize archives.
    public static func read(_ data: Data, limits: Limits = Limits()) throws -> [(path: String, data: Data)] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw ZipError("The file is not a Fieldwork document (too short).") }
        var eocd = -1
        let lowest = max(0, bytes.count - 22 - 65_535)
        var i = bytes.count - 22
        while i >= lowest {
            if bytes.le32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError("The file is not a Fieldwork document (no ZIP directory).") }
        let count = Int(bytes.le16(eocd + 10))
        let centralSize = Int(bytes.le32(eocd + 12))
        let centralOffset = Int(bytes.le32(eocd + 16))
        guard bytes.le16(eocd + 4) == 0, bytes.le16(eocd + 6) == 0 else { throw ZipError("Multi-disk archives are not supported.") }
        guard count <= limits.maxMembers else { throw ZipError("The document has too many members.") }
        guard centralOffset + centralSize <= eocd else { throw ZipError("The ZIP directory is malformed.") }

        var members: [(String, Data)] = []
        var names = Set<String>()
        var total: Int64 = 0
        var p = centralOffset
        for _ in 0..<count {
            guard p + 46 <= eocd, bytes.le32(p) == 0x0201_4b50 else { throw ZipError("The ZIP directory is malformed.") }
            let flags = bytes.le16(p + 8)
            let method = bytes.le16(p + 10)
            let crc = bytes.le32(p + 16)
            let compressed = Int(bytes.le32(p + 20))
            let size = Int(bytes.le32(p + 24))
            let nameLength = Int(bytes.le16(p + 28))
            let extraLength = Int(bytes.le16(p + 30))
            let commentLength = Int(bytes.le16(p + 32))
            let localOffset = Int(bytes.le32(p + 42))
            guard p + 46 + nameLength <= eocd else { throw ZipError("The ZIP directory is malformed.") }
            guard let name = String(bytes: bytes[(p + 46)..<(p + 46 + nameLength)], encoding: .utf8) else {
                throw ZipError("A member name is not valid UTF-8.")
            }
            p += 46 + nameLength + extraLength + commentLength
            try validate(path: name)
            guard names.insert(name).inserted else { throw ZipError("Duplicate member \(name).") }
            guard flags & 0x1 == 0 else { throw ZipError("Encrypted members are not supported.") }
            guard method == 0 else { throw ZipError("Member \(name) uses compression method \(method); this reader accepts stored members only.") }
            guard compressed == size, compressed != 0xFFFF_FFFF else { throw ZipError("Member \(name) has inconsistent sizes.") }
            total += Int64(size)
            guard total <= limits.maxTotalBytes else { throw ZipError("The document expands beyond the allowed size.") }
            guard localOffset + 30 <= bytes.count, bytes.le32(localOffset) == 0x0403_4b50 else { throw ZipError("Member \(name) has a bad local header.") }
            let localName = Int(bytes.le16(localOffset + 26))
            let localExtra = Int(bytes.le16(localOffset + 28))
            let start = localOffset + 30 + localName + localExtra
            guard start + size <= centralOffset else { throw ZipError("Member \(name) extends past its data area.") }
            guard String(bytes: bytes[(localOffset + 30)..<(localOffset + 30 + localName)], encoding: .utf8) == name else {
                throw ZipError("Member \(name) local header does not match the directory.")
            }
            let content = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + size))
            guard CRC32.checksum(content) == crc else { throw ZipError("Member \(name) is damaged (checksum mismatch).") }
            members.append((name, content))
        }
        return members
    }

    /// Member paths are relative, forward-slash separated and never escape the archive.
    public static func validate(path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 512 else { throw ZipError("Invalid member path.") }
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\u{0}") else {
            throw ZipError("Unsafe member path \(path).")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw ZipError("Unsafe member path \(path).") }
    }
}

extension Data {
    mutating func append(le16 v: UInt16) { append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
    mutating func append(le32 v: UInt32) { append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
}

extension Array where Element == UInt8 {
    func le16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func le32(_ i: Int) -> UInt32 { UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24 }
}
