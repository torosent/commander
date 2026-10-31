import Foundation
import Observation

/// One search and its results tab. The tab outlives the bar, so a search can run on behind other work.
@MainActor
@Observable
public final class FindSession {
    public let id = UUID()
    /// Where the results tab is now, which changes if the tab is moved to the other panel.
    public internal(set) var panel: Panel
    public var query = FindQuery() {
        didSet { if query != oldValue { restart() } }
    }
    public var scope = FindScope.volume {
        didSet { if scope != oldValue { restart() } }
    }
    public private(set) var isBarOpen = true
    public private(set) var isSearching = false

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private let volumes: [URL]
    @ObservationIgnored private let showHidden: Bool
    @ObservationIgnored private var control = JobControl()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(panel: Panel, folder: URL, volumes: [URL], showHidden: Bool) {
        self.panel = panel
        self.folder = folder
        self.volumes = volumes
        self.showHidden = showHidden
    }

    /// How the search ended, for anyone who can't see the footer.
    public var summary: String? {
        guard !isSearching, !query.isEmpty else { return nil }
        let count = panel.rows.count
        let found = "\(count.formatted()) item\(count == 1 ? "" : "s") found"
        return panel.findStatus.map { "\(found). \($0)" } ?? found
    }

    /// Waits for the search. Used by tests.
    public func finished() async {
        await task?.value
    }

    func closeBar() {
        isBarOpen = false
    }

    public func stop() {
        control.cancel()
        isSearching = false
    }

    /// Starts over, a moment after the last keystroke.
    private func restart() {
        stop()
        // Replaced even with nothing to search for, or the last search's task still counts as current.
        let control = JobControl()
        self.control = control
        panel.resetResults(id, title: query.title, isEmpty: query.isEmpty)
        guard !query.isEmpty else { return }
        isSearching = true
        let (query, scope, folder, volumes, showHidden) = (query, scope, folder, volumes, showHidden)
        task = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !control.isCancelled else { return }
            let (stream, continuation) = AsyncStream.makeStream(of: [FileEntry].self)
            let running = Task.detached(priority: .userInitiated) {
                // Here rather than on the main actor, because a sleeping network volume can take a while to answer.
                let roots = scope.roots(from: folder, volumes: volumes)
                let finder = FileFinder(query: query, roots: roots, showHidden: showHidden, control: control)
                Spotlight.start(query, in: roots, hits: finder.hits, control: control)
                let outcome = finder.run { continuation.yield($0) }
                continuation.finish()
                return outcome
            }
            for await batch in stream where control === self.control {
                // The tab has gone, so nobody is waiting for this any more.
                if !panel.addResults(batch, to: id) { control.cancel() }
            }
            let outcome = await running.value
            guard control === self.control else { return }
            isSearching = false
            panel.finishResults(id, outcome, isComplete: !control.isCancelled)
        }
    }
}
