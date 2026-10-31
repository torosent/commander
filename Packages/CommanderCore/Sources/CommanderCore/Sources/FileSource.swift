import Foundation

/// A place that can be listed and watched. Local folders implement it now, archives in milestone 6.
public protocol FileSource: Sendable {
    func list(_ url: URL, sort: FileSort) async throws(ListingError) -> Listing
    func watch(_ url: URL, onChange: @escaping @Sendable (FolderChange) -> Void) -> (any FileWatch)?
}

public enum FolderChange: Sendable {
    case contents
    /// The watched folder itself went away, so a new one at that path needs a new watch.
    case folderReplaced
}

public struct Listing: Sendable {
    public var entries: [FileEntry]
    public var freeSpace: Int64?

    public init(entries: [FileEntry], freeSpace: Int64?) {
        self.entries = entries
        self.freeSpace = freeSpace
    }
}

public enum ListingError: Error, Equatable, Sendable {
    case permissionDenied
    case notFound
    case notAFolder
    case other(String)
}

/// Keeps a watch alive. Watching stops when it is cancelled or released.
public protocol FileWatch: AnyObject, Sendable {
    func cancel()
}
