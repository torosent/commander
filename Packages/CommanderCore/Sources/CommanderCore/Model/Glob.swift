import Darwin
import Foundation

/// A list of file name patterns such as `*.js, *.ts`.
public struct Glob: Sendable {
    private let patterns: [String]

    public init(_ text: String) {
        patterns = text.split { ",;".contains($0) }
            .map { $0.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping }
            .filter { !$0.isEmpty }
    }

    /// Both sides are normalized first, because APFS keeps a name in whichever form it was written.
    public func matches(_ name: String) -> Bool {
        let name = name.precomposedStringWithCanonicalMapping
        return patterns.contains { fnmatch($0, name, FNM_CASEFOLD) == 0 }
    }
}

struct MarkPreview: Sendable {
    let glob: Glob
    let marks: Bool
}

/// The inline bar for marking or unmarking by pattern. It keeps the panel it opened on.
@MainActor
public struct PatternBar {
    /// New for each opening, so reopening the bar starts from its own text.
    public let id: Int
    public let panel: Panel
    public let marks: Bool
    public var text: String
}
