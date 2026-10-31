import Darwin
import Foundation

public enum CompareMode: String, CaseIterable, Identifiable, Sendable {
    case nameAndDate, size, content

    public var id: Self { self }
}

/// What a sync should do with a row.
public enum SyncAction: Equatable, Sendable {
    case toRight, toLeft, trash, skip, none
}

/// One side of a row, as it was when compared.
public struct CompareSide: Sendable {
    public let url: URL
    public let name: String
    public let size: Int64
    public let modified: Date
    public let isFolder: Bool
    public let isLink: Bool
}

public struct CompareRow: Identifiable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case same, different, onlyLeft, onlyRight
        /// A file on one side and a folder on the other, which neither can replace.
        case clash
        /// A folder that couldn't be listed or a file that couldn't be read, so it wasn't really compared.
        case unreadable
        /// On one side only, but the other side's volume sees its name as taken.
        case nameTaken
    }

    public let id: Int
    public let depth: Int
    public let left: CompareSide?
    public let right: CompareSide?
    /// A folder on both sides, whose contents follow as their own rows.
    public let isHeader: Bool
    /// Where a copy arriving on each side lands, which is the matched folder and not a guess.
    public let leftFolder: URL
    public let rightFolder: URL
    public let verdict: Verdict
    /// What this row does by default, and what it goes back to.
    public let suggested: SyncAction
    public internal(set) var action: SyncAction

    public var name: String { left?.name ?? right?.name ?? "" }
    /// Identifies the row between comparisons.
    var path: String? { left?.url.path ?? right?.url.path }
    public var isOneSided: Bool { left == nil || right == nil }
}

/// Walks two folders side by side. Links are compared as links and never followed.
public struct TreeComparer: Sendable {
    public let mode: CompareMode
    public let showHidden: Bool
    public let control: JobControl

    /// The system's own housekeeping, which differs between volumes without meaning anything.
    private static let ignored: Set<String> = [".DS_Store", ".Trashes", ".fseventsd", ".Spotlight-V100", ".TemporaryItems"]

    public init(mode: CompareMode, showHidden: Bool, control: JobControl = JobControl()) {
        self.mode = mode
        self.showHidden = showHidden
        self.control = control
    }

    private struct Item {
        let url: URL
        let name: String
        let info: stat

        var isFolder: Bool { info.st_mode & S_IFMT == S_IFDIR }
        var isLink: Bool { info.st_mode & S_IFMT == S_IFLNK }
        var isRegular: Bool { info.st_mode & S_IFMT == S_IFREG }

        /// A folder on one side moves as a whole, so its size is what it holds. Elsewhere it isn't used.
        func side(measuringFolder: Bool = false) -> CompareSide {
            let time = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
            return CompareSide(
                url: url, name: name, size: isFolder && measuringFolder ? LocalSource.measure(url) ?? 0 : Int64(info.st_size),
                modified: Date(timeIntervalSince1970: time),
                isFolder: isFolder, isLink: isLink
            )
        }
    }

    /// What makes two names the same name across these two volumes.
    private struct Rules {
        let ignoresCase: Bool
        let tolerance: TimeInterval

        func key(_ name: String) -> String {
            let form = name.precomposedStringWithCanonicalMapping
            return ignoresCase ? form.lowercased() : form
        }
    }

    public func compare(_ left: URL, _ right: URL) throws(OperationError) -> [CompareRow] {
        // Names can only be told apart by case if both sides can hold the difference.
        let rules = Rules(
            ignoresCase: !Self.isCaseSensitive(left) || !Self.isCaseSensitive(right),
            tolerance: Self.storesCoarseDates(left) || Self.storesCoarseDates(right) ? 2 : 1
        )
        var rows: [CompareRow] = []
        // Failing here rather than guessing: an unlisted side would look like everything is missing from it.
        guard let leftItems = list(left), let rightItems = list(right) else { throw .unsupported("One of the folders can't be read.") }
        try walk(leftItems, rightItems, left, right, depth: 0, rules: rules, into: &rows)
        return rows
    }

    private static func isCaseSensitive(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames ?? false
    }

    /// FAT stores times to two seconds, and these others can sit in front of it.
    private static func storesCoarseDates(_ url: URL) -> Bool {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return false }
        let name = withUnsafeBytes(of: &info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return ["msdos", "exfat", "smbfs"].contains(name)
    }

    private func list(_ folder: URL) -> [Item]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.compactMap { name in
            if Self.ignored.contains(name) || name.hasPrefix("._") { return nil }
            let url = folder.appending(path: name)
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            // A hidden file is never touched unseen, the same as everywhere else.
            if !showHidden, name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0 { return nil }
            return Item(url: url, name: name, info: info)
        }
    }

    /// Pairs by key. Exact names go first, or `A` could take the file `a` was waiting for.
    private func pairs(_ left: [Item], _ right: [Item], _ rules: Rules) -> [(Item?, Item?)] {
        var waiting = Dictionary(grouping: right) { rules.key($0.name) }
        var result: [(Item?, Item?)] = []
        for item in left {
            let key = rules.key(item.name)
            let exact = waiting[key]?.firstIndex { $0.name.precomposedStringWithCanonicalMapping == item.name.precomposedStringWithCanonicalMapping }
            result.append((item, exact.flatMap { waiting[key]?.remove(at: $0) }))
        }
        for index in result.indices where result[index].1 == nil {
            guard let name = result[index].0?.name, waiting[rules.key(name)]?.isEmpty == false else { continue }
            result[index].1 = waiting[rules.key(name)]?.removeFirst()
        }
        result += waiting.values.flatMap { $0 }.map { (nil, $0) }
        return result.sorted { first, second in
            let (a, b) = (first.0 ?? first.1, second.0 ?? second.1)
            if a?.isFolder != b?.isFolder { return a?.isFolder == true }
            return (a?.name ?? "").localizedStandardCompare(b?.name ?? "") == .orderedAscending
        }
    }

    private func walk(
        _ left: [Item], _ right: [Item], _ leftFolder: URL, _ rightFolder: URL, depth: Int, rules: Rules, into rows: inout [CompareRow]
    ) throws(OperationError) {
        let leftKeys = Set(left.map { rules.key($0.name) })
        let rightKeys = Set(right.map { rules.key($0.name) })
        for (first, second) in pairs(left, right, rules) {
            guard !control.isCancelled else { throw .cancelled }
            control.finishItem(settled: 0)
            func add(_ verdict: CompareRow.Verdict, _ action: SyncAction, isHeader: Bool = false) {
                rows.append(CompareRow(
                    id: rows.count, depth: depth, left: first?.side(measuringFolder: second == nil),
                    right: second?.side(measuringFolder: first == nil), isHeader: isHeader,
                    leftFolder: leftFolder, rightFolder: rightFolder, verdict: verdict, suggested: action, action: action
                ))
            }
            guard let first else {
                // A copy could never land if the other side already has this name in another form.
                if let second, leftKeys.contains(rules.key(second.name)) { add(.nameTaken, .none) } else { add(.onlyRight, .toLeft) }
                continue
            }
            guard let second else {
                if rightKeys.contains(rules.key(first.name)) { add(.nameTaken, .none) } else { add(.onlyLeft, .toRight) }
                continue
            }
            if first.isFolder, second.isFolder {
                guard let leftItems = list(first.url), let rightItems = list(second.url) else {
                    add(.unreadable, .none, isHeader: true)
                    continue
                }
                add(.same, .none, isHeader: true)
                try walk(leftItems, rightItems, first.url, second.url, depth: depth + 1, rules: rules, into: &rows)
            } else if first.isFolder != second.isFolder || first.isLink != second.isLink {
                add(.clash, .none)
            } else {
                let (verdict, action) = try judge(first, second, rules)
                add(verdict, action)
            }
        }
    }

    private func judge(_ left: Item, _ right: Item, _ rules: Rules) throws(OperationError) -> (CompareRow.Verdict, SyncAction) {
        let (leftSide, rightSide) = (left.side(), right.side())
        let gap = leftSide.modified.timeIntervalSince(rightSide.modified)
        let newer: SyncAction = abs(gap) < rules.tolerance ? .skip : gap > 0 ? .toRight : .toLeft
        let isSame: Bool
        switch mode {
        case .nameAndDate:
            // The same date with different sizes isn't a match, but nothing says which side is right.
            isSame = abs(gap) < rules.tolerance && leftSide.size == rightSide.size
        case .size:
            isSame = leftSide.size == rightSide.size
        case .content:
            // Without reading both, nothing is known, and a date mustn't be left to suggest an overwrite.
            guard let same = try sameContent(left, right) else { return (.unreadable, .none) }
            isSame = same
        }
        return isSame ? (.same, .none) : (.different, newer)
    }

    /// Nil if either file can't be read.
    private func sameContent(_ left: Item, _ right: Item) throws(OperationError) -> Bool? {
        if left.isLink {
            guard let one = try? FileManager.default.destinationOfSymbolicLink(atPath: left.url.path),
                  let two = try? FileManager.default.destinationOfSymbolicLink(atPath: right.url.path) else { return nil }
            return one == two
        }
        // Opening a named pipe would wait for a writer that may never come.
        guard left.isRegular, right.isRegular, access(left.url.path, R_OK) == 0, access(right.url.path, R_OK) == 0 else { return nil }
        guard left.info.st_size == right.info.st_size else { return false }
        return try Self.sameBytes(left.url, right.url, control: control)
    }

    /// Compares a block at a time, and stops at the first block that differs. Nil if reading fails.
    static func sameBytes(_ left: URL, _ right: URL, control: JobControl) throws(OperationError) -> Bool? {
        let first = open(left.path, O_RDONLY | O_NOFOLLOW)
        guard first >= 0 else { return nil }
        defer { close(first) }
        let second = open(right.path, O_RDONLY | O_NOFOLLOW)
        guard second >= 0 else { return nil }
        defer { close(second) }
        let size = 256 * 1024
        var one = [UInt8](repeating: 0, count: size)
        var two = [UInt8](repeating: 0, count: size)
        while true {
            guard !control.isCancelled else { throw .cancelled }
            let count = read(first, &one, size)
            guard count >= 0 else { return nil }
            var filled = 0
            while filled < count {
                let more = two.withUnsafeMutableBytes { read(second, $0.baseAddress! + filled, count - filled) }
                guard more >= 0 else { return nil }
                // The other file ended first, so they aren't the same.
                guard more > 0 else { return false }
                filled += more
            }
            if count == 0 { return read(second, &two, 1) == 0 }
            guard memcmp(one, two, count) == 0 else { return false }
        }
    }
}
