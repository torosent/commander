import AppKit
import CommanderCore
import SwiftUI
import UniformTypeIdentifiers

/// The icons Finder would show. A row gets its type's icon at once, which reads nothing from disk,
/// and its own one a moment later: an app's, a special folder's, or a custom icon.
@MainActor
enum FileIcons {
    private struct Waiter {
        let url: URL
        let done: @MainActor (NSImage) -> Void
    }

    private static let size = NSSize(width: 16, height: 16)
    private static let queue = DispatchQueue(label: "dev.commander.icons", qos: .userInitiated)
    private static let own: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 4_000
        return cache
    }()
    private static var byType: [String: NSImage] = [:]
    /// Room for every row of two tall panels. Anything older was scrolled past, and asks again if it comes back.
    private static var waiting = NewestFirstQueue<Waiter>(limit: 512)

    static func typeIcon(of fileName: String, isFolder: Bool) -> NSImage {
        let ext = isFolder ? "/" : (fileName as NSString).pathExtension.lowercased()
        if let known = byType[ext] { return known }
        let type = isFolder ? UTType.folder : UTType(filenameExtension: ext) ?? .data
        let image = NSWorkspace.shared.icon(for: type)
        image.size = size
        byType[ext] = image
        return image
    }

    /// With the date in it, so a file given a new icon gets looked at again.
    static func key(_ url: URL, _ modified: Date?) -> String {
        "\(url.path)|\(modified?.timeIntervalSince1970 ?? 0)"
    }

    static func ownIcon(_ key: String) -> NSImage? {
        own.object(forKey: key as NSString)
    }

    /// Off the main thread, because asking can reach a slow volume. Newest first, so what's on screen goes ahead.
    static func load(_ url: URL, key: String, then done: @escaping @MainActor (NSImage) -> Void) {
        if let known = ownIcon(key) { return done(known) }
        waiting.add(key, Waiter(url: url, done: done))
        loadNext()
    }

    /// Made again for a new appearance, because the system draws icons differently in each.
    static func reset() {
        byType = [:]
        own.removeAllObjects()
    }

    private static func loadNext() {
        guard let (key, waiter) = waiting.start() else { return }
        let (url, size) = (waiter.url, size)
        queue.async {
            // A row with no file yet, such as a folder still being named, stays with its type's icon.
            let exists = (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
            nonisolated(unsafe) let image = exists ? NSWorkspace.shared.icon(forFile: url.path) : nil
            image?.size = size
            // These render when first drawn, which would show a blank tile for a moment.
            _ = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let waiters = waiting.finish()
                    if let image {
                        own.setObject(image, forKey: key as NSString)
                        for waiter in waiters { waiter.done(image) }
                    }
                    loadNext()
                }
            }
        }
    }
}

/// A file's icon for the rows drawn in SwiftUI. With no URL, as for a name that doesn't exist yet, it shows the type's.
struct FileIconView: View {
    let name: String
    var url: URL?
    var modified: Date?
    var isFolder = false
    var isDim = false

    @State private var own: NSImage?

    var body: some View {
        Image(nsImage: own ?? FileIcons.typeIcon(of: name, isFolder: isFolder))
            .resizable()
            .frame(width: 16, height: 16)
            .opacity(isDim ? 0.5 : 1)
            .accessibilityHidden(true)
            .task(id: url) {
                own = nil
                guard let url else { return }
                let key = FileIcons.key(url, modified)
                own = FileIcons.ownIcon(key)
                if own == nil { FileIcons.load(url, key: key) { own = $0 } }
            }
    }
}
