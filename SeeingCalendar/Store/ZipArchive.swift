import Compression
import Foundation

// MARK: - 错误

enum ZipArchiveError: LocalizedError {
    case notAnArchive
    case truncated
    case zip64Unsupported
    case entryTooLarge
    case decompressionFailed
    case checksumMismatch(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "不是有效的 ZIP 容器"
        case .truncated: return "归档数据被截断"
        case .zip64Unsupported: return "不支持 ZIP64 归档（单档需小于 4GB）"
        case .entryTooLarge: return "归档超过 4GB 上限"
        case .decompressionFailed: return "Deflate 解压失败"
        case .checksumMismatch(let name): return "校验和不匹配：\(name)"
        case .io(let message): return "读写失败：\(message)"
        }
    }
}

// MARK: - CRC32

enum CRC32 {
    nonisolated(unsafe) private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func compute(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    static func compute(streamOf url: URL, chunkSize: Int = 64 << 10) throws -> (crc: UInt32, size: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipArchiveError.io("无法读取 \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt64 = 0
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            size += UInt64(chunk.count)
            for byte in chunk {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return (crc ^ 0xFFFF_FFFF, size)
    }
}

// MARK: - 小端读写

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func le16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func le32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}

// MARK: - 写入器（STORE：贴图与照片本身已是压缩码流，避免二次压缩的 CPU/内存开销）

struct ZipWriter {
    enum Source {
        case file(URL)
        case data(Data)
    }

    struct Item {
        let name: String
        let source: Source
    }

    /// 流式写盘：内存驻留恒定为一个 chunk，满足大体积归档的 OOM 约束。
    static func write(items: [Item], to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        guard manager.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingAtPath: destination.path) else {
            throw ZipArchiveError.io("无法创建 \(destination.lastPathComponent)")
        }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var records: [(item: Item, crc: UInt32, size: UInt64, offset: UInt64)] = []

        for item in items {
            let nameData = Data(item.name.utf8)
            guard nameData.count <= Int(UInt16.max) else { throw ZipArchiveError.entryTooLarge }

            let checksum: (crc: UInt32, size: UInt64)
            switch item.source {
            case .file(let url): checksum = try CRC32.compute(streamOf: url)
            case .data(let data): checksum = (CRC32.compute(data), UInt64(data.count))
            }
            guard checksum.size < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else {
                throw ZipArchiveError.entryTooLarge
            }

            let (dosTime, dosDate) = dosTimestamp(Date())
            var header = Data()
            header.appendLE(UInt32(0x0403_4B50))
            header.appendLE(UInt16(20))
            header.appendLE(UInt16(0x0800))                     // UTF-8 文件名
            header.appendLE(UInt16(0))                          // method: store
            header.appendLE(dosTime)
            header.appendLE(dosDate)
            header.appendLE(checksum.crc)
            header.appendLE(UInt32(checksum.size))
            header.appendLE(UInt32(checksum.size))
            header.appendLE(UInt16(nameData.count))
            header.appendLE(UInt16(0))
            header.append(nameData)

            let localOffset = offset
            try handle.write(contentsOf: header)
            offset += UInt64(header.count)

            switch item.source {
            case .data(let data):
                try handle.write(contentsOf: data)
                offset += UInt64(data.count)
            case .file(let url):
                offset += try copyFile(at: url, into: handle)
            }

            records.append((item, checksum.crc, checksum.size, localOffset))
        }

        let centralStart = offset
        for record in records {
            let nameData = Data(record.item.name.utf8)
            let (dosTime, dosDate) = dosTimestamp(Date())
            var entry = Data()
            entry.appendLE(UInt32(0x0201_4B50))
            entry.appendLE(UInt16(20))                          // version made by
            entry.appendLE(UInt16(20))                          // version needed
            entry.appendLE(UInt16(0x0800))
            entry.appendLE(UInt16(0))
            entry.appendLE(dosTime)
            entry.appendLE(dosDate)
            entry.appendLE(record.crc)
            entry.appendLE(UInt32(record.size))
            entry.appendLE(UInt32(record.size))
            entry.appendLE(UInt16(nameData.count))
            entry.appendLE(UInt16(0))                           // extra
            entry.appendLE(UInt16(0))                           // comment
            entry.appendLE(UInt16(0))                           // disk start
            entry.appendLE(UInt16(0))                           // internal attrs
            entry.appendLE(UInt32(0))                           // external attrs
            entry.appendLE(UInt32(record.offset))
            entry.append(nameData)
            try handle.write(contentsOf: entry)
            offset += UInt64(entry.count)
        }
        let centralSize = offset - centralStart

        guard records.count <= Int(UInt16.max), centralSize < 0xFFFF_FFFF else {
            throw ZipArchiveError.entryTooLarge
        }

        var end = Data()
        end.appendLE(UInt32(0x0605_4B50))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(0))
        end.appendLE(UInt16(records.count))
        end.appendLE(UInt16(records.count))
        end.appendLE(UInt32(centralSize))
        end.appendLE(UInt32(centralStart))
        end.appendLE(UInt16(0))
        try handle.write(contentsOf: end)
        try handle.close()
    }

    private static func copyFile(at url: URL, into handle: FileHandle) throws -> UInt64 {
        guard let source = try? FileHandle(forReadingFrom: url) else {
            throw ZipArchiveError.io("无法读取 \(url.lastPathComponent)")
        }
        defer { try? source.close() }
        var total: UInt64 = 0
        while true {
            let chunk = (try? source.read(upToCount: 1 << 16)) ?? Data()
            if chunk.isEmpty { break }
            try handle.write(contentsOf: chunk)
            total += UInt64(chunk.count)
        }
        return total
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = CalendarUtils.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let dosTime = UInt16((parts.hour ?? 0) << 11 | (parts.minute ?? 0) << 5 | ((parts.second ?? 0) / 2))
        let dosDate = UInt16(((year - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (dosTime, dosDate)
    }
}

// MARK: - 读取器（以中央目录为唯一索引，兼容 STORE / Deflate 与数据描述符）

struct ZipEntry: Sendable {
    let name: String
    let method: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
}

struct ZipReader {
    private let url: URL
    let entries: [ZipEntry]

    init(url: URL) throws {
        self.url = url
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipArchiveError.io("无法打开 \(url.lastPathComponent)")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 22 else { throw ZipArchiveError.notAnArchive }

        let tailLength = Int(min(size, 66_000))
        let tailOffset = UInt64(size) - UInt64(tailLength)
        try handle.seek(toOffset: tailOffset)
        let tail = (try? handle.read(upToCount: tailLength)) ?? Data()
        guard let eocd = ZipReader.findEOCD(in: tail) else { throw ZipArchiveError.notAnArchive }

        let total = Int(tail.le16(eocd + 10))
        let centralSize = Int(tail.le32(eocd + 12))
        let centralOffset = UInt64(tail.le32(eocd + 16))
        guard centralOffset != 0xFFFF_FFFF, centralSize != Int(0xFFFF_FFFF) else {
            throw ZipArchiveError.zip64Unsupported
        }

        try handle.seek(toOffset: centralOffset)
        let central = (try? handle.read(upToCount: centralSize)) ?? Data()
        var parsed: [ZipEntry] = []
        var cursor = 0
        while cursor + 46 <= central.count, parsed.count < max(total, 1) + 64 {
            guard central.le32(cursor) == 0x0201_4B50 else { break }
            let method = central.le16(cursor + 10)
            let crc = central.le32(cursor + 16)
            let compressed = UInt64(central.le32(cursor + 20))
            let uncompressed = UInt64(central.le32(cursor + 24))
            let nameLength = Int(central.le16(cursor + 28))
            let extraLength = Int(central.le16(cursor + 30))
            let commentLength = Int(central.le16(cursor + 32))
            let localOffset = UInt64(central.le32(cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= central.count else { throw ZipArchiveError.truncated }
            let nameData = central.subdata(in: (central.startIndex + nameStart)..<(central.startIndex + nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF {
                throw ZipArchiveError.zip64Unsupported
            }
            parsed.append(ZipEntry(name: name,
                                   method: method,
                                   crc32: crc,
                                   compressedSize: compressed,
                                   uncompressedSize: uncompressed,
                                   localHeaderOffset: localOffset))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        guard !parsed.isEmpty else { throw ZipArchiveError.notAnArchive }
        self.entries = parsed
    }

    private static func findEOCD(in tail: Data) -> Int? {
        guard tail.count >= 22 else { return nil }
        var index = tail.count - 22
        while index >= 0 {
            if tail.le32(index) == 0x0605_4B50 {
                return index
            }
            index -= 1
        }
        return nil
    }

    func entry(named name: String) -> ZipEntry? {
        entries.first { $0.name == name }
    }

    func entryNames(withPrefix prefix: String) -> [ZipEntry] {
        entries.filter { $0.name.hasPrefix(prefix) }
    }

    func readData(_ entry: ZipEntry, limit: Int = 64 << 20) throws -> Data {
        guard Int(entry.uncompressedSize) <= limit else { throw ZipArchiveError.entryTooLarge }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ZipArchiveError.io("无法打开归档")
        }
        defer { try? handle.close() }
        let payload = try rawPayload(entry, handle: handle)
        let output: Data
        if entry.method == 0 {
            output = payload
        } else if entry.method == 8 {
            output = try ZipReader.inflate(payload, expected: Int(entry.uncompressedSize))
        } else {
            throw ZipArchiveError.decompressionFailed
        }
        guard CRC32.compute(output) == entry.crc32 else {
            throw ZipArchiveError.checksumMismatch(entry.name)
        }
        return output
    }

    func extract(_ entry: ZipEntry, to destination: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: destination)
        try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        manager.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else {
            throw ZipArchiveError.io("无法写入 \(destination.lastPathComponent)")
        }
        defer { try? output.close() }

        guard let input = try? FileHandle(forReadingFrom: url) else {
            throw ZipArchiveError.io("无法打开归档")
        }
        defer { try? input.close() }
        let payload = try rawPayload(entry, handle: input)

        let crc: UInt32
        if entry.method == 0 {
            try output.write(contentsOf: payload)
            crc = CRC32.compute(payload)
        } else if entry.method == 8 {
            let inflated = try ZipReader.inflate(payload, expected: Int(entry.uncompressedSize))
            try output.write(contentsOf: inflated)
            crc = CRC32.compute(inflated)
        } else {
            throw ZipArchiveError.decompressionFailed
        }
        guard crc == entry.crc32 else { throw ZipArchiveError.checksumMismatch(entry.name) }
    }

    private func rawPayload(_ entry: ZipEntry, handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = (try? handle.read(upToCount: 30)) ?? Data()
        guard header.count == 30, header.le32(0) == 0x0403_4B50 else { throw ZipArchiveError.truncated }
        let nameLength = Int(header.le16(26))
        let extraLength = Int(header.le16(28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        try handle.seek(toOffset: dataOffset)
        guard let payload = try? handle.read(upToCount: Int(entry.compressedSize)), payload.count == Int(entry.compressedSize) else {
            throw ZipArchiveError.truncated
        }
        return payload
    }

    /// Apple `Compression` 的 ZLIB 约定存在 raw-deflate / zlib-wrap 两种实现差异，这里做双向尝试。
    static func inflate(_ compressed: Data, expected: Int) throws -> Data {
        if expected == 0 { return Data() }
        if let output = try? decode(compressed, expected: expected) { return output }
        var wrapped = Data([0x78, 0x9C])
        wrapped.append(compressed)
        wrapped.append(contentsOf: [0, 0, 0, 0])
        if let output = try? decode(wrapped, expected: expected) { return output }
        throw ZipArchiveError.decompressionFailed
    }

    private static func decode(_ source: Data, expected: Int) throws -> Data {
        var output = Data(count: expected)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            source.withUnsafeBytes { input -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, destination.count, src, source.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expected else { throw ZipArchiveError.decompressionFailed }
        return output
    }
}

