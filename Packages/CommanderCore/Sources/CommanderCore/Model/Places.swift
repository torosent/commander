import Foundation

/// Somewhere to jump to from the places menu or the path bar.
public struct Place: Identifiable, Hashable, Sendable {
    public var title: String
    public var url: URL

    public var id: URL { url }

    public init(title: String, url: URL) {
        self.title = title
        self.url = url
    }
}

public enum Places {
    public static func favorites(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Place] {
        [Place(title: "Home", url: home)] + ["Desktop", "Documents", "Downloads"].map {
            Place(title: $0, url: home.appending(path: $0, directoryHint: .isDirectory))
        }
    }

    public static func volumes() -> [Place] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.map { url in
            let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
            return Place(title: name ?? url.lastPathComponent, url: url)
        }
    }

    /// The folder holding something, as a person would write it.
    public static func folderText(of url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// Clickable path segments, shortened to `~` inside home and to the volume name on external volumes.
    public static func crumbs(for url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Place] {
        let path = url.standardizedFileURL.pathComponents
        let homePath = home.standardizedFileURL.pathComponents
        if path.starts(with: homePath) {
            return trail(start: Place(title: "~", url: home), path.dropFirst(homePath.count))
        }
        if path.count >= 3, path[1] == "Volumes" {
            let volume = URL(filePath: "/Volumes/\(path[2])", directoryHint: .isDirectory)
            return trail(start: Place(title: path[2], url: volume), path.dropFirst(3))
        }
        return trail(start: Place(title: "/", url: URL(filePath: "/")), path.dropFirst())
    }

    private static func trail(start: Place, _ components: ArraySlice<String>) -> [Place] {
        var crumbs = [start]
        var url = start.url
        for component in components {
            url.append(path: component, directoryHint: .isDirectory)
            crumbs.append(Place(title: component, url: url))
        }
        return crumbs
    }
}
