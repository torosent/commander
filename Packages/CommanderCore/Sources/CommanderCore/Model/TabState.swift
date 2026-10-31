import Foundation

/// One tab's folder, listing and history.
public struct TabState: Sendable {
    /// A remembered place, with the file the cursor was on.
    public struct Stop: Sendable, Equatable {
        public var url: URL
        public var cursor: URL?
    }

    public private(set) var location: URL
    public private(set) var back: [Stop] = []
    public private(set) var forward: [Stop] = []
    public var entries: [FileEntry] = []
    public var sort = FileSort()
    public var failure: ListingError?
    /// Where the cursor was when this tab was last left.
    public var savedCursor: URL?

    public init(location: URL) {
        self.location = location
    }

    public var parent: URL? {
        location.path == "/" ? nil : location.deletingLastPathComponent()
    }

    public var title: String {
        location.path == "/" ? "/" : location.lastPathComponent
    }

    public mutating func go(to url: URL, from cursor: URL?) {
        back.append(Stop(url: location, cursor: cursor))
        forward = []
        location = url
    }

    /// Moves without recording a stop, for when the current folder no longer exists.
    public mutating func relocate(to url: URL) {
        location = url
    }

    /// Returns the file to put the cursor on, or nil when there is no earlier stop.
    public mutating func goBack(from cursor: URL?) -> Stop? {
        guard let stop = back.popLast() else { return nil }
        forward.append(Stop(url: location, cursor: cursor))
        location = stop.url
        return stop
    }

    public mutating func goForward(from cursor: URL?) -> Stop? {
        guard let stop = forward.popLast() else { return nil }
        back.append(Stop(url: location, cursor: cursor))
        location = stop.url
        return stop
    }

    public func rows(showHidden: Bool) -> [FileEntry] {
        let visible = showHidden ? entries : entries.filter { !$0.isHidden }
        return parent.map { [.parent($0)] + visible } ?? visible
    }
}
