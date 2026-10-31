import Foundation

/// What a search has found so far, kept with the tab so it survives leaving and coming back.
public struct FindResults: Sendable, Equatable {
    public let id: UUID
    public var title = "Find"
    public var entries: [FileEntry] = []
    /// False until the search ran to its end, so a shorter list can't pass for the whole answer.
    public var isComplete = true
    public var outcome = FindOutcome()

    public init(id: UUID) {
        self.id = id
    }
}

/// One tab's folder, listing and history.
public struct TabState: Sendable {
    /// A remembered place, with the file the cursor was on.
    public struct Stop: Sendable, Equatable {
        public var url: URL
        public var cursor: URL?
        public var results: FindResults?
    }

    /// Stays with the tab wherever it moves, unlike its position in a panel.
    public let id = UUID()
    public private(set) var location: URL
    public private(set) var back: [Stop] = []
    public private(set) var forward: [Stop] = []
    public var entries: [FileEntry] = []
    public var sort = FileSort()
    public var failure: ListingError?
    /// Where the cursor was when this tab was last left.
    public var savedCursor: URL?
    /// Paths rather than URLs, so a trailing slash can't make one file look like two.
    public var marked: Set<String> = []
    public var folderSizes: [String: Int64] = [:]
    /// Set when this tab shows a search rather than a folder. `location` is where the search began.
    public var results: FindResults?

    public init(location: URL) {
        self.location = location
    }

    public var parent: URL? {
        location.path == "/" || results != nil ? nil : location.deletingLastPathComponent()
    }

    public var title: String {
        results?.title ?? (location.path == "/" ? "/" : location.lastPathComponent)
    }

    public mutating func go(to url: URL, from cursor: URL?) {
        back.append(Stop(url: location, cursor: cursor, results: results))
        forward = []
        location = url
        leaveResults()
    }

    mutating func leaveResults() {
        results = nil
        sort = sort.forFolders
    }

    private mutating func arrive(at stop: Stop) {
        location = stop.url
        results = stop.results
        sort = results == nil ? sort.forFolders : sort.forResults
    }

    /// Moves without recording a stop, for when the current folder no longer exists.
    public mutating func relocate(to url: URL) {
        location = url
    }

    /// Returns the file to put the cursor on, or nil when there is no earlier stop.
    public mutating func goBack(from cursor: URL?) -> Stop? {
        guard let stop = back.popLast() else { return nil }
        forward.append(Stop(url: location, cursor: cursor, results: results))
        arrive(at: stop)
        return stop
    }

    public mutating func goForward(from cursor: URL?) -> Stop? {
        guard let stop = forward.popLast() else { return nil }
        back.append(Stop(url: location, cursor: cursor, results: results))
        arrive(at: stop)
        return stop
    }

    public func rows(showHidden: Bool) -> [FileEntry] {
        let visible = showHidden ? entries : entries.filter { !$0.isHidden }
        return parent.map { [.parent($0)] + visible } ?? visible
    }
}
