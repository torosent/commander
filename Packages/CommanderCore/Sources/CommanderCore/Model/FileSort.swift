import Foundation

public struct FileSort: Hashable, Codable, Sendable {
    public enum Key: String, CaseIterable, Codable, Sendable {
        case name, ext, size, modified
        /// Stands in for the extension in a results tab, whose rows come from many folders.
        case folder
    }

    public var key: Key
    public var ascending: Bool

    public init(key: Key = .name, ascending: Bool = true) {
        self.key = key
        self.ascending = ascending
    }

    /// The same order for a results tab, whose rows have a folder column instead of an extension one.
    var forResults: FileSort { key == .ext ? FileSort(key: .folder, ascending: ascending) : self }
    var forFolders: FileSort { key == .folder ? FileSort(key: .ext, ascending: ascending) : self }

    /// Choosing the current key reverses it. A new key starts ascending.
    public func toggled(_ key: Key) -> FileSort {
        FileSort(key: key, ascending: key == self.key ? !ascending : true)
    }

    /// Folders always come first. `localizedStandardCompare` gives Finder's order: natural numbers,
    /// case-insensitive, and blind to Unicode normalization.
    public func sorted(_ entries: [FileEntry]) -> [FileEntry] {
        entries.sorted(by: precedes)
    }

    public func precedes(_ a: FileEntry, _ b: FileEntry) -> Bool {
        if a.opensAsFolder != b.opensAsFolder { return a.opensAsFolder }
        let order = compare(a, b)
        if order == .orderedSame {
            return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
        }
        return (order == .orderedAscending) == ascending
    }

    private func compare(_ a: FileEntry, _ b: FileEntry) -> ComparisonResult {
        switch key {
        case .name: a.fileName.localizedStandardCompare(b.fileName)
        case .ext: a.ext.localizedStandardCompare(b.ext)
        case .folder: a.url.deletingLastPathComponent().path.localizedStandardCompare(b.url.deletingLastPathComponent().path)
        case .size: order(a.size ?? 0, b.size ?? 0)
        case .modified: order(a.modified ?? .distantPast, b.modified ?? .distantPast)
        }
    }

    private func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}
