import Foundation

/// One row in a panel.
public struct FileEntry: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var ext: String
    public var size: Int64?
    public var modified: Date?
    public var isDirectory: Bool
    public var isPackage: Bool
    public var isSymlink: Bool
    public var isHidden: Bool
    public var isParent: Bool

    public var id: URL { url }

    public init(
        url: URL, fileName: String, size: Int64?, modified: Date?,
        isDirectory: Bool, isPackage: Bool = false, isSymlink: Bool = false, isHidden: Bool = false
    ) {
        self.url = url
        (name, ext) = isDirectory && !isPackage ? (fileName, "") : FileEntry.split(fileName)
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isHidden = isHidden
        isParent = false
    }

    /// The ".." row. Its URL is the parent folder.
    public static func parent(_ url: URL) -> FileEntry {
        var entry = FileEntry(url: url, fileName: "..", size: nil, modified: nil, isDirectory: true)
        entry.isParent = true
        return entry
    }

    /// Whether Return should enter this row rather than open it.
    public var opensAsFolder: Bool { isDirectory && !isPackage }

    public var fileName: String { ext.isEmpty ? name : "\(name).\(ext)" }

    /// A file that opens like a folder. Going by the name means a listing needs no extra reads.
    public var isArchive: Bool { !isDirectory && ArchivePath.isArchiveName(fileName) }

    /// The name and extension of a typed file name.
    public static func nameParts(_ fileName: String) -> (name: String, ext: String) {
        split(fileName)
    }

    /// Splits at the last dot, keeping `.tar.gz` style pairs together. A leading dot isn't a separator.
    static func split(_ fileName: String) -> (name: String, ext: String) {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return (fileName, "") }
        let ext = String(fileName[fileName.index(after: dot)...])
        guard !ext.isEmpty else { return (fileName, "") }
        let stem = String(fileName[..<dot])
        if stem.hasSuffix(".tar"), stem.count > 4 {
            return (String(stem.dropLast(4)), "tar.\(ext)")
        }
        return (stem, ext)
    }
}
