import Darwin
import Foundation

/// Inside an archive, a location is an ordinary path running through the file: `/x/a.zip/sub/file`.
/// That keeps breadcrumbs, history and session restore working without knowing about archives.
public enum ArchivePath {
    private static let wholeNames = [".zip", ".tar", ".tgz", ".tbz", ".tbz2", ".txz", ".7z", ".rar"]
    private static let singleNames = [".gz", ".bz2", ".xz"]

    public static func isArchiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return (wholeNames + singleNames).contains { lower.hasSuffix($0) && lower.count > $0.count }
    }

    /// `.gz` and friends compress one file rather than holding a list of them, unless it's a tar.
    static func isSingleFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return singleNames.contains { lower.hasSuffix($0) } && !lower.contains(".tar.")
    }

    /// The name with the archive's extension gone, for the folder or file it extracts to.
    static func stem(_ name: String) -> String {
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz"] + wholeNames + singleNames where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    /// The archive a path runs through, and the path inside it. Nil for anywhere else.
    /// Only a name ending like an archive costs a look at the disk, so this is cheap for ordinary folders.
    public static func split(_ url: URL) -> (archive: URL, inner: [String])? {
        let parts = url.pathComponents
        guard parts.contains(where: isArchiveName) else { return nil }
        var path = URL(filePath: "/")
        for (index, part) in parts.enumerated().dropFirst() {
            path.append(path: part)
            var info = stat()
            if isArchiveName(part), stat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
                return (path, Array(parts[(index + 1)...]))
            }
        }
        return nil
    }

    /// A path's components if it stays inside wherever it's unpacked. Nil for an absolute path or one
    /// using `..`, which an archive has no honest reason to contain. Every entry goes through here first.
    static func safe(_ path: String) -> [String]? {
        guard !path.hasPrefix("/") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        return parts.contains("..") ? nil : parts
    }
}
