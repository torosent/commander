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
    public private(set) var patternBar: PatternBar?
    public private(set) var volumes: [Place] = []
    /// Bumped to hand keyboard focus back to the active table.
    public private(set) var focusTick = 0

    @ObservationIgnored public var openFile: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var patternOpens = 0

    public init(left: URL, right: URL, source: any FileSource = LocalSource()) {
        panels = [Panel(tabs: [TabState(location: left)], source: source), Panel(tabs: [TabState(location: right)], source: source)]
        for panel in panels { panel.workspace = self }
    }

    /// Restores a saved session. Hidden files come from settings rather than the session.
    public init(session: Session?, fallback: URL, showHidden: Bool = false, source: any FileSource = LocalSource()) {
        let saved = session?.panels ?? []
        panels = (0..<2).map { index in
            let state = saved.indices.contains(index) ? saved[index] : nil
            let tabs = state?.tabs.map(\.restored) ?? []
            let panel = Panel(tabs: tabs.isEmpty ? [TabState(location: fallback)] : tabs, source: source)
            panel.restoreTab(state?.tabIndex ?? 0)
            return panel
        }
        activeIndex = session?.activeIndex == 1 ? 1 : 0
        self.showHidden = showHidden
        for panel in panels { panel.workspace = self }
    }

    public var session: Session {
        Session(panels: panels.map(\.session), activeIndex: activeIndex)
    }

    public var active: Panel { panels[activeIndex] }

    public func start() {
        refreshVolumes()
        for panel in panels { panel.loadSaved() }
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

    // MARK: Pattern marking

    public func beginPattern(marks: Bool) {
        let panel = active
        let ext = panel.cursorEntry?.ext ?? ""
        isGoingToPath = false
        patternBar?.panel.preview(nil, marks: true)
        patternOpens += 1
        patternBar = PatternBar(id: patternOpens, panel: panel, marks: marks, text: ext.isEmpty ? "*" : "*.\(ext)")
        previewPattern()
    }

    public func beginGoTo() {
        if patternBar != nil { cancelPattern() }
        isGoingToPath = true
    }

    public func updatePattern(_ text: String) {
        patternBar?.text = text
        previewPattern()
    }

    public func applyPattern() {
        patternBar?.panel.commitPreview()
        patternBar = nil
        returnFocus()
    }

    public func cancelPattern() {
        patternBar?.panel.preview(nil, marks: true)
        patternBar = nil
        returnFocus()
    }

    /// A preview means nothing once its folder has gone from the panel.
    func folderChanged(in panel: Panel) {
        if patternBar?.panel === panel { cancelPattern() }
    }

    private func previewPattern() {
        guard let bar = patternBar else { return }
        bar.panel.preview(Glob(bar.text), marks: bar.marks)
    }

    /// Keeps a key that isn't wired up yet from looking broken.
    public func notBuilt(_ action: String) {
        say("\(action) arrives in a later milestone.")
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
    /// Changes whenever a row's mark does, so a table redraws only its visible rows.
    public private(set) var marksVersion = 0
    public private(set) var markedCount = 0
    public private(set) var markedSize: Int64 = 0
    public private(set) var query = ""
    public private(set) var queryFailed = false
    /// True while folders are still being measured, so totals may grow.
    public private(set) var isMeasuring = false

    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored private let source: any FileSource
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var watch: (any FileWatch)?
    @ObservationIgnored private var watchedURL: URL?
    @ObservationIgnored private var refreshDelay: Task<Void, Never>?
    @ObservationIgnored private var lastLoadDuration = Duration.zero
    @ObservationIgnored private var measuring: Task<Void, Never>?
    @ObservationIgnored private var measureQueue: [FileEntry] = []
    @ObservationIgnored private var measuringPath: String?
    @ObservationIgnored private var markPreview: MarkPreview?
    @ObservationIgnored private var markCounting: Task<Void, Never>?

    init(tabs: [TabState], source: any FileSource) {
        self.tabs = tabs
        self.source = source
    }

    func restoreTab(_ index: Int) {
        tabIndex = tabs.indices.contains(index) ? index : 0
    }

    var session: PanelSession {
        var saved = tabs
        saved[tabIndex].savedCursor = cursorEntry?.url
        return PanelSession(tabs: saved.map(TabSession.init), tabIndex: tabIndex)
    }

    public var tab: TabState { tabs[tabIndex] }
    public var location: URL { tab.location }
    public var cursorEntry: FileEntry? { rows.indices.contains(cursorIndex) ? rows[cursorIndex] : nil }
    /// What an action would apply to: the marks, or else the cursor's file.
    public var selectionCount: Int { markedCount > 0 ? markedCount : (cursorEntry?.isParent == false ? 1 : 0) }
    public var selectionSize: Int64 { markedCount > 0 ? markedSize : (cursorEntry?.isParent == false ? cursorEntry?.size ?? 0 : 0) }
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

    func loadSaved() {
        load(cursor: tab.savedCursor)
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
            tabs[tabIndex].entries = withKnownSizes(listing.entries)
            tabs[tabIndex].failure = nil
            freeSpace = listing.freeSpace
            startWatching()
            rebuildRows(cursor: cursor)
            measureMarkedFolders()
            return
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

    private func withKnownSizes(_ entries: [FileEntry]) -> [FileEntry] {
        let sizes = tab.folderSizes
        guard !sizes.isEmpty else { return entries }
        return entries.map { entry in
            var entry = entry
            if let size = sizes[entry.url.path] { entry.size = size }
            return entry
        }
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
        // Marks can't outlive their row, so nothing unseen is ever acted on, such as a file that was just hidden.
        if !tab.marked.isEmpty {
            tabs[tabIndex].marked.formIntersection(rows.map(\.url.path))
        }
        refreshMarks()
    }

    // MARK: Cursor

    public func setCursor(_ index: Int) {
        endSearch()
        place(index)
    }

    private func place(_ index: Int) {
        guard !rows.isEmpty else { return }
        cursorIndex = min(max(index, 0), rows.count - 1)
    }

    public func moveCursor(by delta: Int) {
        setCursor(cursorIndex + delta)
    }

    // MARK: Navigation

    public func navigate(to url: URL, cursor: URL? = nil) {
        tabs[tabIndex].go(to: url, from: cursorEntry?.url)
        leaveFolder()
        show(cursor: cursor)
    }

    /// Marks and sizes belong to one visit, so nothing carries into another folder.
    private func leaveFolder() {
        tabs[tabIndex].marked = []
        tabs[tabIndex].folderSizes = [:]
        stopMeasuring()
    }

    private func stopMeasuring() {
        measuring?.cancel()
        measuring = nil
        measureQueue = []
        measuringPath = nil
        isMeasuring = false
    }

    private func show(cursor: URL?) {
        endSearch()
        workspace?.folderChanged(in: self)
        tabs[tabIndex].entries = []
        tabs[tabIndex].failure = nil
        rows = []
        cursorIndex = 0
        rowsVersion += 1
        refreshMarks()
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
        leaveFolder()
        show(cursor: stop.cursor)
    }

    public func goForward() {
        guard let stop = tabs[tabIndex].goForward(from: cursorEntry?.url) else { return }
        leaveFolder()
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
        stopMeasuring()
        show(cursor: tab.savedCursor)
    }

    public func nextTab(by delta: Int) {
        guard tabs.count > 1 else { return }
        selectTab((tabIndex + delta + tabs.count) % tabs.count)
    }

    // MARK: Marks

    public func isMarked(_ entry: FileEntry) -> Bool {
        Self.isMarked(entry, in: tab.marked, preview: markPreview)
    }

    private nonisolated static func isMarked(_ entry: FileEntry, in marked: Set<String>, preview: MarkPreview?) -> Bool {
        guard !entry.isParent else { return false }
        if let preview, !entry.opensAsFolder, preview.glob.matches(entry.fileName) {
            return preview.marks
        }
        return marked.contains(entry.url.path)
    }

    /// Marks the cursor's row and moves down. A folder also has its size measured.
    public func toggleMark() {
        guard let entry = cursorEntry else { return }
        if !entry.isParent {
            let wasMarked = tabs[tabIndex].marked.remove(entry.url.path) != nil
            if !wasMarked { tabs[tabIndex].marked.insert(entry.url.path) }
            // One row changed, so a huge folder needn't be recounted while Space is held down.
            if markPreview == nil {
                markedCount += wasMarked ? -1 : 1
                markedSize += (wasMarked ? -1 : 1) * (entry.size ?? 0)
                marksVersion += 1
            } else {
                refreshMarks()
            }
            if !wasMarked { measure([entry]) }
        }
        moveCursor(by: 1)
    }

    /// Space while searching continues the query if a name really has a space there. Otherwise it marks.
    public func markOrExtendSearch() {
        let extended = query + " "
        if !query.isEmpty, rows.contains(where: { matches($0, extended) }) {
            search(typing: " ")
        } else {
            endSearch()
            toggleMark()
        }
    }

    public func markAll() {
        tabs[tabIndex].marked = Set(rows.filter { !$0.isParent }.map(\.url.path))
        refreshMarks()
        measureMarkedFolders()
    }

    public func clearMarks() {
        tabs[tabIndex].marked = []
        refreshMarks()
    }

    /// Flips files only, so folders aren't swept up in a bulk action.
    public func invertMarks() {
        for entry in rows where !entry.isParent && !entry.opensAsFolder {
            if tabs[tabIndex].marked.remove(entry.url.path) == nil {
                tabs[tabIndex].marked.insert(entry.url.path)
            }
        }
        refreshMarks()
    }

    /// Shows what a pattern would mark without marking anything yet.
    public func preview(_ glob: Glob?, marks: Bool) {
        markPreview = glob.map { MarkPreview(glob: $0, marks: marks) }
        refreshMarks()
    }

    /// Waits for a preview's total. Used by tests.
    public func marksCounted() async {
        await markCounting?.value
    }

    public func commitPreview() {
        var marked = tab.marked
        for entry in rows {
            if isMarked(entry) { marked.insert(entry.url.path) } else { marked.remove(entry.url.path) }
        }
        tabs[tabIndex].marked = marked
        markPreview = nil
        refreshMarks()
        measureMarkedFolders()
    }

    /// Dots update at once. A preview's total is counted off the main actor, since it runs on every keystroke.
    private func refreshMarks() {
        marksVersion += 1
        markCounting?.cancel()
        guard let preview = markPreview else {
            if tab.marked.isEmpty {
                (markedCount, markedSize) = (0, 0)
            } else {
                (markedCount, markedSize) = Self.total(rows, tab.marked, nil)
            }
            return
        }
        let (rows, marked) = (rows, tab.marked)
        markCounting = Task {
            let total = await Task.detached(priority: .userInitiated) { Self.total(rows, marked, preview) }.value
            if !Task.isCancelled { (markedCount, markedSize) = total }
        }
    }

    private nonisolated static func total(_ rows: [FileEntry], _ marked: Set<String>, _ preview: MarkPreview?) -> (Int, Int64) {
        rows.reduce(into: (0, Int64(0))) { total, entry in
            guard isMarked(entry, in: marked, preview: preview) else { return }
            total.0 += 1
            total.1 += entry.size ?? 0
        }
    }

    private func measureMarkedFolders() {
        guard !tab.marked.isEmpty else { return }
        measure(rows.filter { tab.marked.contains($0.url.path) })
    }

    /// Folders are measured one at a time, however many are marked, and sizes land in batches.
    private func measure(_ entries: [FileEntry]) {
        let waiting = Set(measureQueue.map(\.url.path) + [measuringPath].compactMap(\.self))
        measureQueue += entries.filter {
            $0.isDirectory && !$0.isSymlink && $0.size == nil && !waiting.contains($0.url.path)
        }
        guard measuring == nil, !measureQueue.isEmpty else { return }
        isMeasuring = true
        measuring = Task { [source] in
            var found: [String: Int64] = [:]
            var flushed = ContinuousClock.now
            while !measureQueue.isEmpty {
                let entry = measureQueue.removeFirst()
                measuringPath = entry.url.path
                let size = await source.folderSize(entry.url)
                guard !Task.isCancelled else { return }
                found[entry.url.path] = size
                guard measureQueue.isEmpty || .now - flushed > .milliseconds(250) else { continue }
                tabs[tabIndex].folderSizes.merge(found) { $1 }
                found = [:]
                flushed = .now
                // shortcut: a size sort isn't redone when a size arrives. Sort again to include it.
                tabs[tabIndex].entries = withKnownSizes(tab.entries)
                rebuildRows()
            }
            measuring = nil
            measuringPath = nil
            isMeasuring = false
        }
    }

    // MARK: Quick search

    public func search(typing text: String) {
        query += text
        findQuery()
    }

    /// Returns false when there was nothing to erase.
    public func eraseSearch() -> Bool {
        guard !query.isEmpty else { return false }
        query.removeLast()
        if query.isEmpty { endSearch() } else { findQuery() }
        return true
    }

    public func endSearch() {
        query = ""
        queryFailed = false
    }

    private func matches(_ entry: FileEntry, _ text: String) -> Bool {
        !entry.isParent && entry.fileName.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private func findQuery() {
        let match = rows.firstIndex { matches($0, query) }
        queryFailed = match == nil
        if let match { place(match) }
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
