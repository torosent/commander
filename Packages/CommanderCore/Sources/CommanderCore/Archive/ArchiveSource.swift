import Darwin
import Foundation

/// An archive's contents as a tree, read once from its headers.
struct ArchiveIndex: Sendable {
    struct Node: Sendable {
        var isFolder: Bool
        var isLink = false
        var size: Int64?
        var modified: Date?
    }

    private(set) var folders: [String: [String: Node]] = ["": [:]]
    /// True if the archive broke off, so what's here is only the part before the damage.
    private(set) var isDamaged = false

    init(_ url: URL) throws(ArchiveError) {
        let reader = try ArchiveReader(url)
        var count = 0
        while true {
            // Thrown rather than returned, because a partial index would be cached as the whole archive.
            if Task.isCancelled { throw .cancelled }
            let header: ArchiveReader.Header
            do throws(ArchiveError) {
                guard let next = try reader.next() else { break }
                header = next
            } catch {
                // What came before the damage can still be seen and copied out.
                guard error != .passwordProtected, count > 0 else { throw error }
                isDamaged = true
                break
            }
            count += 1
            // An unsafe path never shows, so what's listed is what can be extracted.
            guard let parts = ArchivePath.safe(header.path), let name = parts.last else { continue }
            var folder = ""
            // Plenty of archives never list their folders, only the files in them.
            for part in parts.dropLast() {
                if folders[folder, default: [:]][part]?.isFolder != true {
                    folders[folder, default: [:]][part] = Node(isFolder: true)
                }
                folder = folder.isEmpty ? part : "\(folder)/\(part)"
                if folders[folder] == nil { folders[folder] = [:] }
            }
            var isLink = false
            if case .link = header.kind { isLink = true }
            let isFolder = header.kind == .folder
            folders[folder, default: [:]][name] = Node(isFolder: isFolder, isLink: isLink, size: isFolder ? nil : header.size, modified: header.modified)
            if isFolder, folders[parts.joined(separator: "/")] == nil { folders[parts.joined(separator: "/")] = [:] }
        }
    }

    /// The rows for a folder inside the archive, or nil if there's no such folder.
    func entries(in inner: [String], of archive: URL) -> [FileEntry]? {
        guard let nodes = folders[inner.joined(separator: "/")] else { return nil }
        let base = inner.reduce(archive) { $0.appending(path: $1) }
        return nodes.map { name, node in
            FileEntry(
                url: base.appending(path: name), fileName: name, size: node.size, modified: node.modified,
                isDirectory: node.isFolder, isSymlink: node.isLink, isHidden: name.hasPrefix(".")
            )
        }
    }

    /// The total size of a folder's files.
    func size(of inner: [String]) -> Int64? {
        let path = inner.joined(separator: "/")
        guard let nodes = folders[path] else { return nil }
        return nodes.reduce(0) { total, item in
            let child = inner + [item.key]
            return total + (item.value.isFolder ? size(of: child) ?? 0 : item.value.size ?? 0)
        }
    }
}

/// Keeps the last few archives' indexes, because reading a tar.gz's headers means unpacking all of it.
private actor ArchiveCache {
    static let shared = ArchiveCache()

    private var stored: [String: (stamp: String, index: ArchiveIndex)] = [:]

    func index(of url: URL) async throws(ArchiveError) -> ArchiveIndex {
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw .unreadable("it has gone") }
        let stamp = "\(info.st_size)-\(info.st_mtimespec.tv_sec)-\(info.st_mtimespec.tv_nsec)"
        if let hit = stored[url.path], hit.stamp == stamp { return hit.index }
        let reading = Task.detached(priority: .userInitiated) { () -> Result<ArchiveIndex, ArchiveError> in
            do throws(ArchiveError) {
                return .success(try ArchiveIndex(url))
            } catch {
                return .failure(error)
            }
        }
        let index = try await withTaskCancellationHandler { await reading.value } onCancel: { reading.cancel() }.get()
        if stored.count >= 8, let oldest = stored.keys.first { stored[oldest] = nil }
        stored[url.path] = (stamp, index)
        return index
    }
}

/// Sends a path running through an archive to the archive, and everything else to the disk.
public struct RoutedSource: FileSource {
    private let local = LocalSource()

    public init() {}

    public func list(_ url: URL, sort: FileSort) async throws(ListingError) -> Listing {
        guard let (archive, inner) = ArchivePath.split(url) else { return try await local.list(url, sort: sort) }
        let index: ArchiveIndex
        do throws(ArchiveError) {
            index = try await ArchiveCache.shared.index(of: archive)
        } catch {
            throw .other(error.message)
        }
        guard let entries = index.entries(in: inner, of: archive) else { throw .notFound }
        let notice = index.isDamaged ? "This archive is damaged, so only part of it is listed." : nil
        return Listing(entries: sort.sorted(entries), freeSpace: nil, notice: notice)
    }

    /// An archive is read-only here, so there's nothing to watch.
    public func watch(_ url: URL, onChange: @escaping @Sendable (FolderChange) -> Void) -> (any FileWatch)? {
        ArchivePath.split(url) == nil ? local.watch(url, onChange: onChange) : nil
    }

    public func folderSize(_ url: URL) async -> Int64? {
        guard let (archive, inner) = ArchivePath.split(url) else { return await local.folderSize(url) }
        do throws(ArchiveError) {
            return try await ArchiveCache.shared.index(of: archive).size(of: inner)
        } catch {
            return nil
        }
    }
}
