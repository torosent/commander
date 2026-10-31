import Darwin
import Foundation
import os

public enum FindScope: String, CaseIterable, Identifiable, Sendable {
    case folder, volume, allVolumes

    public var id: Self { self }

    /// Where a search starts. Real paths, so Spotlight's hits and the walk's name files the same way.
    func roots(from folder: URL, volumes: [URL]) -> [URL] {
        let real = FileNames.realPath(folder).map { URL(filePath: $0, directoryHint: .isDirectory) } ?? folder
        switch self {
        case .folder: return [real]
        case .volume: return [Self.volumeRoot(of: real)]
        case .allVolumes:
            var seen = Set<String>()
            return ([Self.volumeRoot(of: real)] + volumes.map(Self.volumeRoot)).filter { seen.insert($0.path).inserted }
        }
    }

    /// The startup disk is two volumes shown as one, and `/` is the way into both.
    private static func volumeRoot(of url: URL) -> URL {
        let root = (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume ?? URL(filePath: "/")
        return root.path == "/System/Volumes/Data" ? URL(filePath: "/") : root
    }
}

/// What to look for. A name with `*`, `?` or a comma is a mask, and anything else matches inside the name.
public struct FindQuery: Equatable, Sendable {
    public var name = ""
    public var contains = ""

    public init(name: String = "", contains: String = "") {
        self.name = name
        self.contains = contains
    }

    private var pattern: String { name.trimmingCharacters(in: .whitespaces) }
    private var isMask: Bool { pattern.contains { "*?[,;".contains($0) } }

    public var isEmpty: Bool { pattern.isEmpty && contains.isEmpty }

    /// What a results tab is called.
    var title: String {
        pattern.isEmpty ? contains.isEmpty ? "Find" : "Find: “\(contains)”" : "Find: \(pattern)"
    }

    /// A good guess for Spotlight, because every hit is checked again. Built from arguments rather than
    /// a query string, because a string Spotlight can't parse raises an exception Swift can't catch.
    var spotlightPredicate: NSPredicate? {
        var parts: [NSPredicate] = []
        if !pattern.isEmpty {
            guard !pattern.contains("[") else { return nil }
            let masks = isMask ? pattern.split { ",;".contains($0) }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : ["*\(Self.literal(pattern))*"]
            let names = masks.map { NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, $0) }
            guard let first = names.first else { return nil }
            // Spotlight raises an exception on a compound of one.
            parts.append(names.count == 1 ? first : NSCompoundPredicate(orPredicateWithSubpredicates: names))
        }
        if !contains.isEmpty {
            parts.append(NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemTextContentKey, Self.literal(contains) + "*"))
        }
        return parts.count < 2 ? parts.first : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    private static func literal(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
    }

    fileprivate func nameMatcher() -> @Sendable (String) -> Bool {
        let pattern = pattern
        guard !pattern.isEmpty else { return { _ in true } }
        if isMask {
            let glob = Glob(pattern)
            return { glob.matches($0) }
        }
        return { $0.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

/// How a search ended.
public struct FindOutcome: Sendable, Equatable {
    public var unreadable = 0
    public var reachedLimit = false
}

/// Finds files by walking folders, with Spotlight's hits taken as they come so most show in the first moments.
/// The walk decides what counts, so an indexed volume and an unindexed one give the same answer,
/// and a folder Spotlight doesn't cover can't quietly come back empty.
public struct FileFinder: Sendable {
    static let limit = 100_000

    public let query: FindQuery
    public let roots: [URL]
    public let showHidden: Bool
    public let control: JobControl
    let hits = SpotlightHits()

    private static let keys: Set<URLResourceKey> = [.isHiddenKey, .isPackageKey, .isVolumeKey, .isRegularFileKey]

    public init(query: FindQuery, roots: [URL], showHidden: Bool, control: JobControl = JobControl()) {
        self.query = query
        self.roots = roots
        self.showHidden = showHidden
        self.control = control
    }

    /// Hands over results in batches as they turn up.
    public func run(emit: @escaping @Sendable ([FileEntry]) -> Void) -> FindOutcome {
        let pass = Pass(self, emit: emit)
        for root in roots where !pass.isDone { walk(root, pass) }
        takeHits(pass)
        pass.flush()
        hits.close()
        return pass.outcome
    }

    private func takeHits(_ pass: Pass) {
        for url in hits.take() where !pass.isDone && reachable(url, pass) { pass.consider(url) }
    }

    private func walk(_ root: URL, _ pass: Pass) {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(Self.keys), options: []) { _, _ in
            pass.outcome.unreadable += 1
            return true
        }
        guard let walker else { return }
        var going = true
        while going {
            // Without a pool of its own, a walk of a whole disk holds on to every URL it passed.
            going = autoreleasepool {
                takeHits(pass)
                guard !pass.isDone, let url = walker.nextObject() as? URL else { return false }
                guard let values = try? url.resourceValues(forKeys: Self.keys) else { return true }
                if isSkipped(url, values) {
                    walker.skipDescendants()
                } else {
                    if values.isPackage == true { walker.skipDescendants() }
                    pass.consider(url)
                }
                return true
            }
        }
    }

    /// A folder is left out with everything in it, the way a panel with hidden files off would.
    private func isSkipped(_ url: URL, _ values: URLResourceValues) -> Bool {
        // The sealed system, which nobody manages by hand and which would drown every search.
        values.isVolume == true || url.path == "/System" || (!showHidden && values.isHidden == true)
    }

    /// Whether the walk would get to this hit. Spotlight knows nothing of what the walk skips.
    private func reachable(_ url: URL, _ pass: Pass) -> Bool {
        guard let root = Self.root(of: url, in: roots) else { return false }
        guard let values = try? url.resourceValues(forKeys: Self.keys), !isSkipped(url, values) else { return false }
        var folder = url.deletingLastPathComponent()
        var passed: [String] = []
        while folder.path != root.path, !pass.openFolders.contains(folder.path) {
            guard let values = try? folder.resourceValues(forKeys: Self.keys), !isSkipped(folder, values), values.isPackage != true else { return false }
            passed.append(folder.path)
            folder.deleteLastPathComponent()
        }
        pass.openFolders.formUnion(passed)
        return true
    }

    /// The deepest root holding a file, because with all volumes searched, `/` holds every path.
    static func root(of url: URL, in roots: [URL]) -> URL? {
        roots.filter { url.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }.max { $0.path.count < $1.path.count }
    }

    /// A file iCloud has taken off the disk, which reading would quietly download.
    static func isPlaceholder(_ info: stat) -> Bool {
        info.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Folds ASCII case in the file as it reads, and looks across block edges.
    /// shortcut: other letters match by exact bytes in UTF-8, so no accents or UTF-16. Decode text if that's missed.
    static func contains(_ url: URL, _ needle: [UInt8], control: JobControl) -> Bool? {
        // No pipes or links here: the caller checked it's a regular file, and this holds if it was swapped since.
        let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, !isPlaceholder(info) else { return nil }
        let size = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: size + needle.count)
        var kept = 0
        while !control.isCancelled {
            let count = buffer.withUnsafeMutableBytes { read(file, $0.baseAddress! + kept, size) }
            guard count >= 0 else { return nil }
            guard count > 0 else { return false }
            let total = kept + count
            let found = buffer.withUnsafeMutableBytes { bytes -> Bool in
                for index in kept..<total where bytes[index] >= 65 && bytes[index] <= 90 { bytes[index] += 32 }
                return memmem(bytes.baseAddress!, total, needle, needle.count) != nil
            }
            if found { return true }
            kept = min(needle.count - 1, total)
            buffer.withUnsafeMutableBytes { bytes in memmove(bytes.baseAddress!, bytes.baseAddress! + total - kept, kept) }
        }
        return false
    }

    /// One search's running state.
    private final class Pass {
        let finder: FileFinder
        let emit: ([FileEntry]) -> Void
        let matchesName: (String) -> Bool
        let needle: [UInt8]
        var outcome = FindOutcome()
        var seen = Set<String>()
        var openFolders = Set<String>()
        var batch: [FileEntry] = []
        var found = 0
        var flushed = ContinuousClock.now

        init(_ finder: FileFinder, emit: @escaping ([FileEntry]) -> Void) {
            self.finder = finder
            self.emit = emit
            matchesName = finder.query.nameMatcher()
            needle = finder.query.contains.utf8.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        }

        var isDone: Bool { outcome.reachedLimit || finder.control.isCancelled }

        func consider(_ url: URL) {
            // By one Unicode form, because Spotlight and the walk needn't spell a path alike.
            guard matchesName(url.lastPathComponent), seen.insert(url.path.precomposedStringWithCanonicalMapping).inserted else { return }
            if !needle.isEmpty {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return }
                guard let found = FileFinder.contains(url, needle, control: finder.control) else {
                    outcome.unreadable += 1
                    return
                }
                guard found else { return }
            }
            guard !finder.control.isCancelled, let entry = LocalSource.entry(url) else { return }
            batch.append(entry)
            found += 1
            if found >= FileFinder.limit { outcome.reachedLimit = true }
            if batch.count >= 2_000 || .now - flushed > .milliseconds(150) { flush() }
        }

        func flush() {
            flushed = .now
            guard !batch.isEmpty else { return }
            emit(batch)
            batch = []
        }
    }
}

/// Hits on their way from Spotlight to a walk already under way.
final class SpotlightHits: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (waiting: [URL](), isClosed: false))

    /// True once the walk has finished, when anything more would be of no use.
    var isClosed: Bool { state.withLock(\.isClosed) }

    func offer(_ urls: [URL]) {
        state.withLock { $0.waiting += urls }
    }

    func take() -> [URL] {
        state.withLock { state in
            defer { state.waiting = [] }
            return state.waiting
        }
    }

    func close() {
        state.withLock { $0.isClosed = true }
    }
}

enum Spotlight {
    private static let limit = 20_000

    /// Gets a query going on a thread of its own, which is the only place it's ever touched.
    /// Stopping a query waits on Metadata's queue, which can be waiting on the thread that asked: on the main
    /// thread that froze the app, and on a shared one it starved everything else. Here the worst case is one
    /// stuck thread, and the walk still finishes the search.
    static func start(_ find: FindQuery, in roots: [URL], hits: SpotlightHits, control: JobControl) {
        Thread.detachNewThread { run(find, in: roots, hits: hits, control: control) }
    }

    /// Blocks until gathering ends, the search does, or Spotlight has had long enough.
    /// Nothing comes back from a volume that isn't indexed.
    static func run(_ find: FindQuery, in roots: [URL], hits: SpotlightHits, control: JobControl) {
        guard let predicate = find.spotlightPredicate else { return }
        let query = NSMetadataQuery()
        query.predicate = predicate
        query.searchScopes = roots
        nonisolated(unsafe) var hasNews = false
        nonisolated(unsafe) var isGathered = false
        let center = NotificationCenter.default
        // No queue, so these arrive on this thread, and work waits until they've returned.
        let observers = [
            center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query, queue: nil) { _ in hasNews = true },
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil) { _ in
                hasNews = true
                isGathered = true
            },
        ]
        defer { observers.forEach(center.removeObserver) }
        var handedOver = 0
        func handOver() {
            hasNews = false
            query.disableUpdates()
            defer { query.enableUpdates() }
            let end = min(query.resultCount, limit)
            guard handedOver < end else { return }
            hits.offer((handedOver..<end).compactMap { index in
                ((query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(filePath: $0) }
            })
            handedOver = end
        }
        query.start()
        let deadline = Date.now.addingTimeInterval(30)
        while !isGathered, !control.isCancelled, !hits.isClosed, Date.now < deadline {
            RunLoop.current.run(mode: .default, before: .now.addingTimeInterval(0.05))
            if hasNews { handOver() }
        }
        if hasNews { handOver() }
        query.stop()
    }
}
