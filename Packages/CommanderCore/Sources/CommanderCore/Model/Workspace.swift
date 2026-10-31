import Foundation
import Observation

/// The two panels and everything shared between them.
@MainActor
@Observable
public final class Workspace {
    public let panels: [Panel]
    public private(set) var activeIndex = 0
    public private(set) var showHidden = false
    public var message: String?
    public var isGoingToPath = false
    public private(set) var volumes: [Place] = []
    /// Bumped to hand keyboard focus back to the active table.
    public private(set) var focusTick = 0

    @ObservationIgnored public var openFile: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored private var messageTask: Task<Void, Never>?

    public init(left: URL, right: URL, source: any FileSource = LocalSource()) {
        panels = [Panel(location: left, source: source), Panel(location: right, source: source)]
        for panel in panels { panel.workspace = self }
    }

    public var active: Panel { panels[activeIndex] }

    public func start() {
        refreshVolumes()
        for panel in panels { panel.refresh() }
    }

    public func refreshVolumes() {
        volumes = Places.volumes()
    }

    public func activate(_ index: Int) {
        activeIndex = index
    }

    public func switchPanel() {
        activeIndex = 1 - activeIndex
    }

    public func returnFocus() {
        focusTick += 1
    }

    public func toggleHidden() {
        showHidden.toggle()
        for panel in panels { panel.rebuildRows() }
    }

    public func say(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task {
            try? await Task.sleep(for: .seconds(4.5))
            if !Task.isCancelled { message = nil }
        }
    }

    /// Goes to a typed path. Returns what went wrong, if anything.
    public func goTo(path: String) async -> String? {
        let typed = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !typed.isEmpty else { return "Enter a folder path." }
        let url = typed.hasPrefix("/")
            ? URL(filePath: typed, directoryHint: .isDirectory)
            : active.location.appending(path: typed, directoryHint: .isDirectory)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else {
            return "That folder does not exist."
        }
        active.navigate(to: url.standardizedFileURL)
        return nil
    }
}

/// One panel: its tabs and what the current tab shows.
@MainActor
@Observable
public final class Panel {
    public private(set) var tabs: [TabState]
    public private(set) var tabIndex = 0
    public private(set) var rows: [FileEntry] = []
    public private(set) var cursorIndex = 0
    /// Changes whenever `rows` does, so a table reloads only when it must.
    public private(set) var rowsVersion = 0
    public private(set) var freeSpace: Int64?
    public private(set) var isLoading = false

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private let source: any FileSource
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var watch: (any FileWatch)?
    @ObservationIgnored private var watchedURL: URL?
    @ObservationIgnored private var refreshDelay: Task<Void, Never>?
    @ObservationIgnored private var lastLoadDuration = Duration.zero

    init(location: URL, source: any FileSource) {
        tabs = [TabState(location: location)]
        self.source = source
    }

    public var tab: TabState { tabs[tabIndex] }
    public var location: URL { tab.location }
    public var cursorEntry: FileEntry? { rows.indices.contains(cursorIndex) ? rows[cursorIndex] : nil }
    public var canGoBack: Bool { !tab.back.isEmpty }
    public var canGoForward: Bool { !tab.forward.isEmpty }
    public var hiddenCount: Int { (workspace?.showHidden ?? false) ? 0 : tab.entries.count { $0.isHidden } }
    public var visibleCount: Int { tab.entries.count - hiddenCount }
    public var visibleSize: Int64 {
        let showHidden = workspace?.showHidden ?? false
        return tab.entries.reduce(0) { $0 + (showHidden || !$1.isHidden ? $1.size ?? 0 : 0) }
    }

    // MARK: Loading

    /// Waits for the current load. Used by tests and at launch.
    public func loaded() async {
        await loading?.value
    }

    public func refresh() {
        load(cursor: cursorEntry?.url)
    }

    private func load(cursor: URL?, followMissing: Bool = false) {
        generation += 1
        let current = generation
        let url = location
        let sort = tab.sort
        refreshDelay?.cancel()
        refreshDelay = nil
        isLoading = true
        loading?.cancel()
        let started = ContinuousClock.now
        loading = Task { [source] in
            let result: Result<Listing, ListingError>
            do throws(ListingError) {
                result = .success(try await source.list(url, sort: sort))
            } catch {
                result = .failure(error)
            }
            guard current == generation else { return }
            isLoading = false
            lastLoadDuration = .now - started
            apply(result, cursor: cursor, followMissing: followMissing)
        }
    }

    private func apply(_ result: Result<Listing, ListingError>, cursor: URL?, followMissing: Bool) {
        switch result {
        case .success(let listing):
            tabs[tabIndex].entries = listing.entries
            tabs[tabIndex].failure = nil
            freeSpace = listing.freeSpace
            startWatching()
        case .failure(let error):
            if error == .notFound, followMissing, let existing = nearestExisting() {
                workspace?.say("That folder is gone, so this panel moved to \(existing.lastPathComponent).")
                replaceLocation(with: existing)
                return
            }
            tabs[tabIndex].entries = []
            tabs[tabIndex].failure = error
            freeSpace = nil
            stopWatching()
        }
        rebuildRows(cursor: cursor)
    }

    private func nearestExisting() -> URL? {
        var url = location
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func replaceLocation(with url: URL) {
        tabs[tabIndex].relocate(to: url)
        load(cursor: nil)
    }

    private func startWatching() {
        guard watchedURL != location else { return }
        watchedURL = location
        watch = source.watch(location) { [weak self] change in
            Task { @MainActor in self?.scheduleRefresh(after: change) }
        }
    }

    private func stopWatching() {
        watch = nil
        watchedURL = nil
    }

    /// Changes coalesce into one refresh, and a folder that never stops changing still updates.
    /// The wait scales with the last load, so a huge busy folder doesn't reload constantly.
    private func scheduleRefresh(after change: FolderChange) {
        if change == .folderReplaced { stopWatching() }
        guard refreshDelay == nil else { return }
        refreshDelay = Task {
            try? await Task.sleep(for: max(.milliseconds(150), lastLoadDuration))
            if !Task.isCancelled { load(cursor: cursorEntry?.url, followMissing: true) }
        }
    }

    /// Rebuilds rows from the listing. The cursor stays on its file, or at the same position if that file went.
    func rebuildRows(cursor: URL? = nil) {
        // Paths, not URLs: a typed location and a listed one can differ by a trailing slash.
        let keep = (cursor ?? cursorEntry?.url)?.path
        let previous = cursorIndex
        rows = tab.rows(showHidden: workspace?.showHidden ?? false)
        cursorIndex = rows.firstIndex { $0.url.path == keep } ?? min(previous, max(rows.count - 1, 0))
        rowsVersion += 1
    }

    // MARK: Cursor

    public func setCursor(_ index: Int) {
        guard !rows.isEmpty else { return }
        cursorIndex = min(max(index, 0), rows.count - 1)
    }

    public func moveCursor(by delta: Int) {
        setCursor(cursorIndex + delta)
    }

    // MARK: Navigation

    public func navigate(to url: URL, cursor: URL? = nil) {
        tabs[tabIndex].go(to: url, from: cursorEntry?.url)
        show(cursor: cursor)
    }

    private func show(cursor: URL?) {
        tabs[tabIndex].entries = []
        tabs[tabIndex].failure = nil
        rows = []
        cursorIndex = 0
        rowsVersion += 1
        load(cursor: cursor)
    }

    /// Return on the cursor row. Packages open unless `asFolder` is set.
    public func openCursor(asFolder: Bool = false) {
        guard let entry = cursorEntry else { return }
        if entry.isParent {
            goUp()
        } else if entry.opensAsFolder || (asFolder && entry.isDirectory) {
            navigate(to: entry.url)
        } else {
            workspace?.openFile(entry.url)
        }
    }

    public func goUp() {
        guard let parent = tab.parent else { return }
        navigate(to: parent, cursor: location)
    }

    public func goBack() {
        guard let stop = tabs[tabIndex].goBack(from: cursorEntry?.url) else { return }
        show(cursor: stop.cursor)
    }

    public func goForward() {
        guard let stop = tabs[tabIndex].goForward(from: cursorEntry?.url) else { return }
        show(cursor: stop.cursor)
    }

    // MARK: Tabs

    public func newTab() {
        var tab = TabState(location: location)
        tab.sort = self.tab.sort
        tab.savedCursor = cursorEntry?.url
        tabs.insert(tab, at: tabIndex + 1)
        selectTab(tabIndex + 1)
    }

    public func closeTab() {
        guard tabs.count > 1 else { return }
        tabs.remove(at: tabIndex)
        showTab(min(tabIndex, tabs.count - 1))
    }

    public func selectTab(_ index: Int) {
        guard index != tabIndex else { return }
        tabs[tabIndex].savedCursor = cursorEntry?.url
        showTab(index)
    }

    private func showTab(_ index: Int) {
        tabIndex = index
        stopWatching()
        show(cursor: tab.savedCursor)
    }

    public func nextTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        selectTab((tabIndex + delta + tabs.count) % tabs.count)
    }

    // MARK: Sorting

    public func sort(by key: FileSort.Key) {
        tabs[tabIndex].sort = tab.sort.toggled(key)
        // A load in flight has the old order, so restart it with the new one.
        guard !isLoading else { return load(cursor: cursorEntry?.url) }
        generation += 1
        let current = generation
        let (entries, sort, cursor) = (tab.entries, tab.sort, cursorEntry?.url)
        isLoading = true
        loading = Task {
            let sorted = await Task.detached(priority: .userInitiated) { sort.sorted(entries) }.value
            guard current == generation else { return }
            isLoading = false
            tabs[tabIndex].entries = sorted
            rebuildRows(cursor: cursor)
        }
    }
}
