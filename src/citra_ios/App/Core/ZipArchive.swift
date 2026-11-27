// Copyright 2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv3 or any later version
// Refer to the LICENSE.txt file included.

import Compression
import Foundation

/// A small reader and writer of ZIP files, for the save data of games: a folder is written as a
/// ZIP without compression (saves are small), and ZIPs from other tools (stored or deflated) can
/// be read. No ZIP64, encryption or multi-disk archives.
enum ZipArchive {
    enum ZipError: LocalizedError {
        case notAZip
        case unsupported(String)
        case corrupt(String)
        case tooBig

        var errorDescription: String? {
            switch self {
            case .notAZip: return "That file is not a ZIP archive."
            case .unsupported(let what): return "The ZIP uses something that is not supported (\(what))."
            case .corrupt(let name): return "The ZIP is damaged (\(name))."
            case .tooBig: return "The folder is too big for a ZIP."
            }
        }
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }

    // MARK: Writing

    /// Writes the contents of a folder (not the folder itself) as a ZIP.
    static func write(contentsOf directory: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        var files: [(path: String, url: URL?)] = []
        let base = directory.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            throw ZipError.notAZip
        }
        for case let url as URL in enumerator {
            var path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            path.removeFirst(base.count)
            while path.hasPrefix("/") { path.removeFirst() }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            files.append(isDirectory ? (path + "/", nil) : (path, url))
        }
        files.sort { $0.path < $1.path }
        guard files.count < 0xFFFF else { throw ZipError.tooBig }

        let (date, time) = dosDateTime(Date())
        var output = Data()
        var central = Data()
        for entry in files {
            let name = Data(entry.path.utf8)
            let content = entry.url.flatMap { try? Data(contentsOf: $0) } ?? Data()
            guard content.count < 0xFFFF_FFFF, output.count < 0xFFFF_FFFF else { throw ZipError.tooBig }
            let crc = crc32(content)
            let offset = UInt32(output.count)
            // Local header
            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))
            output.appendLE(UInt16(0x0800)) // UTF-8 names
            output.appendLE(UInt16(0))      // stored
            output.appendLE(time)
            output.appendLE(date)
            output.appendLE(crc)
            output.appendLE(UInt32(content.count))
            output.appendLE(UInt32(content.count))
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(name)
            output.append(content)
            // Central directory entry
            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(UInt16(0))
            central.appendLE(time)
            central.appendLE(date)
            central.appendLE(crc)
            central.appendLE(UInt32(content.count))
            central.appendLE(UInt32(content.count))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(entry.url == nil ? UInt32(0x10) : UInt32(0)) // MS-DOS directory bit
            central.appendLE(offset)
            central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count))
        output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))
        try output.write(to: destination, options: .atomic)
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = max((parts.year ?? 1980) - 1980, 0)
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = (parts.second ?? 0) / 2
        let dosDate = UInt16((year << 9) | (month << 5) | day)
        let dosTime = UInt16((hour << 11) | (minute << 5) | second)
        return (dosDate, dosTime)
    }

    // MARK: Reading

    /// Extracts a ZIP into a folder (which is created). Names that would leave the folder are
    /// refused, and the junk of macOS (`__MACOSX`, `.DS_Store`) is skipped.
    static func extract(_ zip: URL, to destination: URL) throws {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        guard data.count >= 22 else { throw ZipError.notAZip }
        // The end of central directory record is in the last 64 KiB.
        var end = data.count - 22
        let lowest = max(0, data.count - 22 - 0xFFFF)
        while end >= lowest, data.u32(at: end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw ZipError.notAZip }
        let count = Int(data.u16(at: end + 10))
        var position = Int(data.u32(at: end + 16))
        if count == 0xFFFF || position == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let root = destination.standardizedFileURL.path

        for _ in 0..<count {
            guard position + 46 <= data.count, data.u32(at: position) == 0x0201_4B50 else {
                throw ZipError.corrupt("directory")
            }
            let flags = data.u16(at: position + 8)
            let method = data.u16(at: position + 10)
            let crc = data.u32(at: position + 16)
            let compressedSize = Int(data.u32(at: position + 20))
            let size = Int(data.u32(at: position + 24))
            let nameLength = Int(data.u16(at: position + 28))
            let extraLength = Int(data.u16(at: position + 30))
            let commentLength = Int(data.u16(at: position + 32))
            let localOffset = Int(data.u32(at: position + 42))
            guard position + 46 + nameLength <= data.count else { throw ZipError.corrupt("directory") }
            let name = String(decoding: data[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            position += 46 + nameLength + extraLength + commentLength
            if flags & 1 != 0 { throw ZipError.unsupported("encryption") }
            if compressedSize == 0xFFFF_FFFF || size == 0xFFFF_FFFF { throw ZipError.unsupported("ZIP64") }

            let components = name.split(separator: "/", omittingEmptySubsequences: true)
            if components.contains("..") || name.hasPrefix("/") || name.contains("\\") {
                throw ZipError.corrupt(name)
            }
            if components.first == "__MACOSX" || components.last == ".DS_Store" { continue }
            let target = destination.appendingPathComponent(components.joined(separator: "/"))
            guard target.standardizedFileURL.path.hasPrefix(root) else { throw ZipError.corrupt(name) }
            if name.hasSuffix("/") {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            guard localOffset + 30 <= data.count, data.u32(at: localOffset) == 0x0403_4B50 else {
                throw ZipError.corrupt(name)
            }
            let start = localOffset + 30 + Int(data.u16(at: localOffset + 26))
                + Int(data.u16(at: localOffset + 28))
            guard start + compressedSize <= data.count else { throw ZipError.corrupt(name) }
            let stored = data.subdata(in: start..<(start + compressedSize))
            let content: Data
            switch method {
            case 0:
                content = stored
            case 8:
                content = try inflate(stored, size: size, name: name)
            default:
                throw ZipError.unsupported("compression method \(method)")
            }
            guard content.count == size, crc32(content) == crc else { throw ZipError.corrupt(name) }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try content.write(to: target)
        }
    }

    private static func inflate(_ data: Data, size: Int, name: String) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ZipError.corrupt(name) }
        return output
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    func u16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
    }
}
