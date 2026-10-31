import Foundation

/// What survives a relaunch: tabs, folders, sort order and cursors.
public struct Session: Codable, Equatable, Sendable {
    public var panels: [PanelSession]
    public var activeIndex: Int
}

public struct PanelSession: Codable, Equatable, Sendable {
    public var tabs: [TabSession]
    public var tabIndex: Int
}

public struct TabSession: Codable, Equatable, Sendable {
    public var path: String
    public var sort: FileSort
    public var cursor: String?

    init(_ tab: TabState) {
        path = tab.location.path
        // A results tab comes back as a folder.
        sort = tab.sort.forFolders
        cursor = tab.savedCursor?.path
    }

    /// A folder that has gone since last time falls back to its nearest surviving parent.
    var restored: TabState {
        var url = URL(filePath: path, directoryHint: .isDirectory)
        while url.path != "/", !FileManager.default.fileExists(atPath: url.path) {
            url = url.deletingLastPathComponent()
        }
        var tab = TabState(location: url)
        tab.sort = sort
        tab.savedCursor = cursor.map { URL(filePath: $0) }
        return tab
    }
}
