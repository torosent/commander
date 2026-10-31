import Foundation

/// Two text files lined up, for the compare screen.
public enum TextDiff {
    public struct Row: Identifiable, Sendable, Equatable {
        public let id: Int
        public let left: String?
        public let right: String?
        public var isChanged: Bool { left != right }
    }

    public enum Failure: Error, Equatable, Sendable {
        case tooLarge
        case tooDifferent
        case notText
    }

    private static let limit = 2 * 1024 * 1024
    /// The diff's cost grows with how much differs rather than with file size, so this limits the
    /// lines left after trimming the matching ends. A large file with a small change stays cheap.
    private static let changedLimit = 6_000

    public static func rows(_ left: URL, _ right: URL) throws(Failure) -> [Row] {
        try rows(try lines(left), try lines(right))
    }

    private static func lines(_ url: URL) throws(Failure) -> [String] {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        // A link's size says nothing about what it leads to, and a pipe might never end.
        guard values?.isRegularFile == true else { throw .notText }
        guard values?.fileSize ?? 0 <= limit else { throw .tooLarge }
        guard let data = try? Data(contentsOf: url), !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw .notText
        }
        // By scalar, because to Swift "\r\n" is one character and never equals "\n".
        var lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func rows(_ left: [String], _ right: [String]) throws(Failure) -> [Row] {
        var head = 0
        while head < min(left.count, right.count), left[head] == right[head] { head += 1 }
        var tail = 0
        while tail < min(left.count, right.count) - head, left[left.count - 1 - tail] == right[right.count - 1 - tail] { tail += 1 }
        let oldMiddle = left[head..<(left.count - tail)]
        let newMiddle = right[head..<(right.count - tail)]
        guard oldMiddle.count + newMiddle.count <= changedLimit else { throw .tooDifferent }

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newMiddle.difference(from: oldMiddle) {
            switch change {
            case .remove(let offset, _, _): removed.insert(head + offset)
            case .insert(let offset, _, _): inserted.insert(head + offset)
            }
        }
        var rows: [Row] = []
        var (one, two) = (0, 0)
        while one < left.count || two < right.count {
            let goes = one < left.count && removed.contains(one)
            let comes = two < right.count && inserted.contains(two)
            if goes, comes {
                rows.append(Row(id: rows.count, left: left[one], right: right[two]))
                one += 1
                two += 1
            } else if goes {
                rows.append(Row(id: rows.count, left: left[one], right: nil))
                one += 1
            } else if comes {
                rows.append(Row(id: rows.count, left: nil, right: right[two]))
                two += 1
            } else {
                rows.append(Row(id: rows.count, left: left[one], right: right[two]))
                one += 1
                two += 1
            }
        }
        return rows
    }
}
