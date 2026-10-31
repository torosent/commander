import Darwin
import Foundation

public struct LocalSource: FileSource {
    public init() {}

    public func list(_ url: URL, sort: FileSort) async throws(ListingError) -> Listing {
        // Listing can block on slow or network volumes, so it stays off the caller's actor.
        let reading = Task.detached(priority: .userInitiated) { () -> Result<Listing, ListingError> in
            Result { try Self.read(url, sort: sort) }.mapError { $0 as? ListingError ?? .other($0.localizedDescription) }
        }
        let result = await withTaskCancellationHandler { await reading.value } onCancel: { reading.cancel() }
        return try result.get()
    }

    public func watch(_ url: URL, onChange: @escaping @Sendable (FolderChange) -> Void) -> (any FileWatch)? {
        DirectoryWatch(url, onChange: onChange)
    }

    public func folderSize(_ url: URL) async -> Int64? {
        let measuring = Task.detached(priority: .utility) { Self.measure(url) }
        return await withTaskCancellationHandler { await measuring.value } onCancel: { measuring.cancel() }
    }

    static func measure(_ url: URL) -> Int64? {
        // The enumerator doesn't descend into symlinks, so a link can't count a folder twice or loop.
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            if Task.isCancelled { return nil }
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey,
    ]

    private static func read(_ url: URL, sort: FileSort) throws -> Listing {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch {
            throw listingError(error)
        }
        var entries: [FileEntry] = []
        entries.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            if let entry = entry(url) { entries.append(entry) }
        }
        try Task.checkCancellation()
        let free = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        // The important-usage figure counts purgeable space, but reads 0 on volumes that don't track it.
        let important = free?.volumeAvailableCapacityForImportantUsage ?? 0
        let freeSpace = important > 0 ? important : free?.volumeAvailableCapacity.map(Int64.init)
        return Listing(entries: sort.sorted(entries), freeSpace: freeSpace)
    }

    /// Describes one file, for files arriving from the clipboard or a drag.
    public static func entry(_ url: URL) -> FileEntry? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isSymlink = values.isSymbolicLink ?? false
        // A link to a folder should navigate like a folder. Listing never recurses, so following one here is safe.
        let isDirectory = isSymlink
            ? ((try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
            : (values.isDirectory ?? false)
        return FileEntry(
            url: url,
            fileName: url.lastPathComponent,
            size: isDirectory ? nil : values.fileSize.map(Int64.init),
            modified: values.contentModificationDate,
            isDirectory: isDirectory,
            isPackage: values.isPackage ?? false,
            isSymlink: isSymlink,
            isHidden: values.isHidden ?? false
        )
    }

    private static func listingError(_ error: Error) -> ListingError {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError: return .permissionDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            default: break
            }
        }
        switch (underlying ?? error).code {
        case Int(EACCES), Int(EPERM): return .permissionDenied
        case Int(ENOENT): return .notFound
        case Int(ENOTDIR): return .notAFolder
        default: return .other(error.localizedDescription)
        }
    }
}

/// Watches one folder's entries. shortcut: no events on network volumes, so panels there need manual refresh.
private final class DirectoryWatch: FileWatch, @unchecked Sendable {
    private let source: any DispatchSourceFileSystemObject

    init?(_ url: URL, onChange: @escaping @Sendable (FolderChange) -> Void) {
        let descriptor = Darwin.open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .global(qos: .utility)
        )
        let events = source
        source.setEventHandler {
            onChange(events.data.isDisjoint(with: [.delete, .rename, .revoke]) ? .contents : .folderReplaced)
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
