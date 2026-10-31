import Foundation
import Observation

public enum CaseChange: String, CaseIterable, Identifiable, Sendable {
    case keep, lower, upper, title

    public var id: Self { self }
}

/// What the multi-rename screen's fields say.
public struct RenameOptions: Equatable, Sendable {
    public var name = "[N]-[YMD]"
    public var ext = "[E]"
    public var find = ""
    public var replacement = ""
    public var usesRegex = false
    public var caseChange = CaseChange.keep
    public var counterStart = 1
    public var counterStep = 1
    public var counterDigits = 2

    public init() {}
}

/// One file before and after.
public struct RenameRow: Identifiable, Sendable {
    public let entry: FileEntry
    public let name: String
    public let ext: String
    public var problem: String?

    public var id: URL { entry.url }
    public var fileName: String { ext.isEmpty ? name : "\(name).\(ext)" }
    public var isChanged: Bool { fileName != entry.fileName }
}

/// A piece of a name template.
private enum Token {
    case literal(String)
    case name(from: Int?, to: Int?)
    case ext, counter, date

    static func parse(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var rest = template[...]
        while let match = rest.firstMatch(of: /\[N(?:(\d+)(?:-(\d+))?)?\]|\[E\]|\[C\]|\[YMD\]/) {
            if match.range.lowerBound > rest.startIndex {
                tokens.append(.literal(String(rest[..<match.range.lowerBound])))
            }
            switch match.output.0 {
            case "[E]": tokens.append(.ext)
            case "[C]": tokens.append(.counter)
            case "[YMD]": tokens.append(.date)
            default: tokens.append(.name(from: match.output.1.flatMap { Int($0) }, to: match.output.2.flatMap { Int($0) }))
            }
            rest = rest[match.range.upperBound...]
        }
        if !rest.isEmpty { tokens.append(.literal(String(rest))) }
        return tokens
    }
}

public enum RenamePlan {
    /// Every file's new name and anything wrong with it. `taken` holds the keys of names in the
    /// folder that aren't in the set, so `a→b` with `b→a` is fine and hitting a bystander isn't.
    public static func rows(_ files: [FileEntry], _ options: RenameOptions, taken: Set<String>, caseSensitive: Bool = false) -> [RenameRow] {
        let name = Token.parse(options.name)
        let ext = Token.parse(options.ext)
        let regex = options.usesRegex && !options.find.isEmpty ? try? NSRegularExpression(pattern: options.find) : nil
        let badRegex = options.usesRegex && !options.find.isEmpty && regex == nil

        var rows = files.enumerated().map { index, file -> RenameRow in
            let counter = options.counterStart + index * options.counterStep
            func fill(_ tokens: [Token]) -> String {
                tokens.map { text(of: $0, in: file, counter: counter, digits: options.counterDigits) }.joined()
            }
            var newName = fill(name)
            if let regex {
                let whole = NSRange(newName.startIndex..., in: newName)
                newName = regex.stringByReplacingMatches(in: newName, range: whole, withTemplate: options.replacement)
            } else if !options.find.isEmpty, !badRegex {
                // A plain replacement, so a $ in it means a dollar sign.
                newName = newName.replacingOccurrences(of: options.find, with: options.replacement)
            }
            newName = changeCase(newName, options.caseChange)
            var row = RenameRow(entry: file, name: newName, ext: fill(ext))
            if badRegex {
                row.problem = "The search pattern isn't valid."
            } else if newName.isEmpty {
                row.problem = "A name is empty."
            } else if row.isChanged {
                // Only new names are judged, so a file staying as it is can't hold up the rest.
                row.problem = FileNames.problem(with: row.fileName)
            }
            return row
        }

        var uses: [String: Int] = [:]
        for row in rows { uses[key(row.fileName, caseSensitive: caseSensitive), default: 0] += 1 }
        for index in rows.indices where rows[index].problem == nil {
            let key = key(rows[index].fileName, caseSensitive: caseSensitive)
            if uses[key, default: 0] > 1 {
                rows[index].problem = "Two files would get the same name. Add [C] to number them."
            } else if rows[index].isChanged, taken.contains(key) {
                rows[index].problem = "That name is already in this folder."
            }
        }
        return rows
    }

    /// What makes two names the same name on this volume.
    static func key(_ name: String, caseSensitive: Bool) -> String {
        caseSensitive ? name.precomposedStringWithCanonicalMapping : FileNames.key(name: name)
    }

    private static func text(of token: Token, in file: FileEntry, counter: Int, digits: Int) -> String {
        switch token {
        case .literal(let text): return text
        case .ext: return file.ext
        case .counter:
            let number = String(abs(counter))
            return (counter < 0 ? "-" : "") + String(repeating: "0", count: max(digits - number.count, 0)) + number
        case .date:
            guard let modified = file.modified else { return "" }
            // The local date, as shown in the Modified column.
            let date = Calendar.current.dateComponents([.year, .month, .day], from: modified)
            return String(format: "%04d%02d%02d", date.year ?? 0, date.month ?? 0, date.day ?? 0)
        case .name(let from, let to):
            guard let from else { return file.name }
            return String(Array(file.name).dropFirst(max(from - 1, 0)).prefix(max((to ?? from) - max(from - 1, 0), 0)))
        }
    }

    private static func changeCase(_ name: String, _ change: CaseChange) -> String {
        switch change {
        case .keep: return name
        case .lower: return name.lowercased()
        case .upper: return name.uppercased()
        case .title:
            // Only first letters change, so ALL-CAPS words stay as they are.
            var result = ""
            var atStart = true
            for character in name {
                result += atStart ? character.uppercased() : String(character)
                atStart = !(character.isLetter || character.isNumber)
            }
            return result
        }
    }
}

/// The multi-rename screen's state, from opening it until it's run or cancelled.
@MainActor
@Observable
public final class RenameSession {
    public let panel: Panel
    public let folder: URL
    public let files: [FileEntry]
    public var options = RenameOptions() {
        didSet { if options != oldValue { rebuild() } }
    }
    public private(set) var rows: [RenameRow] = []
    public private(set) var firstProblem: RenameRow?
    public private(set) var problemCount = 0
    public private(set) var changedCount = 0

    @ObservationIgnored private let taken: Set<String>
    @ObservationIgnored private let caseSensitive: Bool

    init(panel: Panel, files: [FileEntry]) {
        self.panel = panel
        folder = panel.location
        self.files = files
        // From the disk rather than the rows, because a hidden file can hold a name too.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: panel.location.path)) ?? []
        let volume = try? panel.location.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        let isCaseSensitive = volume?.volumeSupportsCaseSensitiveNames ?? false
        caseSensitive = isCaseSensitive
        let own = Set(files.map { RenamePlan.key($0.fileName, caseSensitive: isCaseSensitive) })
        taken = Set(names.map { RenamePlan.key($0, caseSensitive: isCaseSensitive) }).subtracting(own)
        rebuild()
    }

    private func rebuild() {
        rows = RenamePlan.rows(files, options, taken: taken, caseSensitive: caseSensitive)
        firstProblem = rows.first { $0.problem != nil }
        problemCount = rows.count { $0.problem != nil }
        changedCount = rows.count { $0.isChanged && $0.problem == nil }
    }

    public var canRun: Bool { problemCount == 0 && changedCount > 0 }

    /// The renames as a plan the job queue can run, leaving out files that don't change.
    var preview: OperationPreview {
        let items = rows.filter(\.isChanged).map {
            PlannedItem(source: $0.entry, target: folder.appending(path: $0.fileName), existing: nil)
        }
        return OperationPreview(kind: .rename, folder: folder, items: items, alreadyThere: 0)
    }
}
