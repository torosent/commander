import Darwin
import Foundation

public enum ViewerError: Error, Equatable, Sendable {
    case unreadable(Int32)
    case notAFile
    case notDownloaded
}

/// Reads a file of any size a window at a time. Nothing scans the whole file, so a multi-GB log opens
/// at once. Plain reads rather than a memory map, because a mapped file that shrinks or whose volume
/// goes away kills the process, and logs get rotated while they're being read.
public final class PagedFile {
    public struct Row: Equatable, Sendable {
        public let offset: Int64
        public let text: String
        /// Where the row after this one starts.
        public let next: Int64
    }

    private static let tabWidth = 4
    /// How far back to look for the start of a line. Longer lines are entered part-way through.
    private static let lineSearch: Int64 = 64 * 1024
    /// A jump further than this into a line stays where it landed rather than going back to the line's start.
    private static let snapLimit: Int64 = 4 * 1024

    private let descriptor: Int32

    public init(_ url: URL) throws(ViewerError) {
        // Non-blocking, because opening a pipe would otherwise wait for a writer forever.
        descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw .unreadable(errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw .notAFile
        }
        // Reading a cloud placeholder downloads it, and a moving cursor shouldn't fetch every file it passes.
        if info.st_flags & UInt32(SF_DATALESS) != 0 {
            close(descriptor)
            throw .notDownloaded
        }
    }

    deinit {
        close(descriptor)
    }

    /// Asked each time, so a growing log shows its new lines.
    public var size: Int64 {
        var info = stat()
        return fstat(descriptor, &info) == 0 ? Int64(info.st_size) : 0
    }

    private func bytes(at offset: Int64, count: Int) -> [UInt8] {
        guard count > 0 else { return [] }
        return [UInt8](unsafeUninitializedCapacity: count) { buffer, filled in
            filled = max(pread(descriptor, buffer.baseAddress, count, off_t(offset)), 0)
        }
    }

    /// A NUL, or text that isn't UTF-8, in the first few KB.
    public var looksBinary: Bool {
        var sample = bytes(at: 0, count: 8 * 1024)
        if sample.contains(0) { return true }
        // A character cut off by the end of the sample doesn't count.
        if sample.count == 8 * 1024 {
            while let last = sample.last, last & 0x80 != 0 { sample.removeLast() }
        }
        return String(validating: sample, as: UTF8.self) == nil
    }

    // MARK: Text

    /// Rows starting at `offset`, wrapped at `columns`.
    public func rows(from offset: Int64, count: Int, columns: Int) -> [Row] {
        let window = bytes(at: offset, count: count * (columns * 4 + 1))
        var rows: [Row] = []
        var start = 0
        while rows.count < count, start < window.count {
            var index = start
            var width = 0
            while index < window.count, window[index] != 0x0A {
                // Continuation bytes take no width, so a wrap never lands inside a character.
                let needed = window[index] & 0xC0 == 0x80 ? 0 : window[index] == 0x09 ? Self.tabWidth : 1
                if width + needed > columns, width > 0 { break }
                width += needed
                index += 1
            }
            let next = index < window.count && window[index] == 0x0A ? index + 1 : index
            rows.append(Row(offset: offset + Int64(start), text: Self.display(window[start..<index]), next: offset + Int64(next)))
            start = next
        }
        return rows
    }

    private static func display(_ bytes: ArraySlice<UInt8>) -> String {
        let text = String(decoding: bytes, as: UTF8.self)
        guard bytes.contains(where: { $0 < 0x20 }) else { return text }
        var shown = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\t": shown += String(repeating: " ", count: tabWidth)
            case "\r": continue
            case _ where scalar.value < 0x20: shown += "·"
            default: shown.unicodeScalars.append(scalar)
            }
        }
        return shown
    }

    /// Where the row `count` rows above `offset` starts.
    public func start(rowsBefore offset: Int64, count: Int, columns: Int) -> Int64 {
        var starts: [Int64] = []
        var end = min(offset, size)
        while starts.count < count, end > 0 {
            let line = lineStart(before: end)
            let span = Int((end - line) / Int64(columns)) * 4 + 2
            starts = rows(from: line, count: span, columns: columns).map(\.offset).filter { $0 < end } + starts
            end = line
        }
        return starts.suffix(count).first ?? 0
    }

    /// The nearest row start at or before `offset`, for jumping by the scroller.
    public func rowStart(near offset: Int64) -> Int64 {
        guard offset > 0 else { return 0 }
        let target = min(offset, size - 1)
        let line = lineStart(before: target + 1)
        if target - line <= Self.snapLimit { return line }
        let boundary = bytes(at: target, count: 4).firstIndex { $0 & 0xC0 != 0x80 } ?? 0
        return target + Int64(boundary)
    }

    /// The start of the line holding the byte before `end`.
    private func lineStart(before end: Int64) -> Int64 {
        let from = max(end - 1 - Self.lineSearch, 0)
        let window = bytes(at: from, count: Int(end - 1 - from))
        if let newline = window.lastIndex(of: 0x0A) { return from + Int64(newline) + 1 }
        guard from > 0 else { return 0 }
        let boundary = window.firstIndex { $0 & 0xC0 != 0x80 } ?? 0
        return from + Int64(boundary)
    }

    // MARK: Hex

    /// How many bytes fit on a hex row of `columns`, in whole groups of eight.
    public static func hexWidth(columns: Int) -> Int {
        // Offset and gap take 14, each byte 3 plus 1 in the text column, and each group a gap and the bars 3.
        columns >= 83 ? 16 : 8
    }

    /// Rows of offset, bytes and text.
    public func hexRows(from offset: Int64, count: Int, width: Int) -> [Row] {
        let window = bytes(at: offset, count: count * width)
        return stride(from: 0, to: window.count, by: width).map { start in
            let line = window[start..<min(start + width, window.count)]
            let at = offset + Int64(start)
            var hex = ""
            for (index, byte) in line.enumerated() {
                if index > 0, index % 8 == 0 { hex += " " }
                hex += Self.pair(byte) + " "
            }
            let padding = width * 3 + (width - 1) / 8 - hex.count
            let text = String(line.map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
            let label = String(repeating: "0", count: max(12 - String(at, radix: 16).count, 0)) + String(at, radix: 16)
            return Row(offset: at, text: "\(label)  \(hex)\(String(repeating: " ", count: max(padding, 0))) |\(text)|", next: at + Int64(line.count))
        }
    }

    private static func pair(_ byte: UInt8) -> String {
        byte < 0x10 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
    }
}
