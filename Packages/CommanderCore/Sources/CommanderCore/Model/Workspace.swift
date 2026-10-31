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
    public private(set) var pending: PendingOperation?
    /// These stay until dismissed, oldest first, because a failure shouldn't vanish on a timer or to a later job.
    public private(set) var reports: [JobReport] = []
    public var report: JobReport? { reports.first }
    /// True while the command line has focus, so commands don't take its keystrokes.
    public var isCommandLineFocused = false
    public let jobs = JobQueue()
    /// Shown in the panel opposite the active one.
    public private(set) var viewer: Viewer?
    /// The multi-rename screen, which takes the place of the panels while open.
    public private(set) var renameSession: RenameSession?
    /// The compare screen, which also takes the place of the panels.
    public private(set) var compareSession: CompareSession?
    public private(set) var isPaletteOpen = false
    /// The command line command still running.
    public private(set) var runningCommand: String?
    /// Bumped to hand keyboard focus to the viewer, or to the command line.
    public private(set) var viewerFocusTick = 0
    public private(set) var commandLineTick = 0
    public private(set) var volumes: [Place] = []
    /// Bumped to hand keyboard focus back to the active table.
    public private(set) var focusTick = 0

    @ObservationIgnored public var openFile: @MainActor (URL) -> Void = { _ in }
    @ObservationIgnored public var desktop = Desktop()
    /// The window's, handed over by the table.
    @ObservationIgnored public weak var undoManager: UndoManager?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var wasStopped = false
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var patternOpens = 0
    @ObservationIgnored private var planning: Task<Void, Never>?

    public init(left: URL, right: URL, source: any FileSource = RoutedSource()) {
        panels = [Panel(tabs: [TabState(location: left)], source: source), Panel(tabs: [TabState(location: right)], source: source)]
        connect()
    }

    /// Restores a saved session. Hidden files come from settings rather than the session.
    public init(session: Session?, fallback: URL, showHidden: Bool = false, source: any FileSource = RoutedSource()) {
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
        connect()
    }

    private func connect() {
        for panel in panels { panel.workspace = self }
        jobs.onFinish = { [weak self] report in self?.finished(report) }
    }

    private func finished(_ report: JobReport) {
        for panel in panels { panel.refresh(following: report.renames) }
        if report.kind == .sync { compareSession?.reload(keepingSkips: true) }
        let isUndoable = !report.renames.isEmpty && !report.isUndo
        if isUndoable { registerUndo(of: report.renames) }
        if report.needsAttention {
            reports.append(report)
        } else {
            say(isUndoable ? "\(report.summary) Press ⌘Z to undo." : report.summary)
        }
    }

    /// True while a bar or an inline edit is open, which another bar shouldn't open on top of.
    /// The keys reach these even when `isTyping` holds the menus back.
    private var hasOpenField: Bool {
        patternBar != nil || isGoingToPath || panels.contains { $0.edit != nil }
    }

    public var isTyping: Bool {
        isGoingToPath || patternBar != nil || isCommandLineFocused || isPaletteOpen || renameSession != nil || compareSession != nil || panels.contains { $0.edit != nil }
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

    /// With the viewer open, the other side is the viewer, so focus goes there instead.
    public func switchPanel() {
        if viewer != nil {
            viewerFocusTick += 1
        } else {
            activeIndex = 1 - activeIndex
        }
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
        if let pending, pending.source === panel || pending.destination === panel { cancelOperation() }
        if renameSession?.panel === panel { cancelRename() }
        if compareSession != nil { closeCompare() }
    }

    // MARK: Operations

    /// Plans an operation on the selection, or on `entries` if given. Nothing happens until it's run.
    public func begin(_ kind: OperationKind, entries: [FileEntry]? = nil, into folder: URL? = nil) {
        guard pending == nil, planning == nil, !hasOpenField else { return }
        let other = panels[1 - activeIndex]
        let home = entries?.first.flatMap { FileNames.realPath($0.url.deletingLastPathComponent()) }
        let source = entries == nil ? active : [active, other].first { FileNames.realPath($0.location) == home }
        let isTransfer = kind == .copy || kind == .move || kind == .extract
        let target = isTransfer ? folder ?? other.location : nil
        let destination = isTransfer ? panels.first { $0.location.path == target?.path } : nil
        let sources = entries ?? active.selectionEntries
        let origin = source?.location
        planning = Task {
            let plan = await Task.detached(priority: .userInitiated) { () -> Result<OperationPreview, OperationRefusal> in
                do throws(OperationRefusal) {
                    return .success(try OperationPreview.plan(kind, sources: sources, into: target))
                } catch {
                    return .failure(error)
                }
            }.value
            planning = nil
            // A panel that moved on while this ran no longer shows what the plan describes.
            guard source?.location == origin, destination == nil || destination?.location.path == target?.path else { return }
            switch plan {
            case .success(let preview):
                // A transfer previews in the other panel, so it has to be showing.
                if isTransfer, viewer != nil { closeViewer() }
                pending = PendingOperation(preview: preview, source: source, destination: destination, choice: preview.defaultChoice)
                showPending(scroll: true)
            case .failure(let refusal):
                say(refusal.message)
            }
        }
    }

    /// Waits for a plan to appear. Used by tests.
    public func planned() async {
        await planning?.value
    }

    public func choose(_ choice: ConflictChoice) {
        pending?.choice = choice
        showPending(scroll: false)
    }

    /// Packs the selection into a new archive in the other panel, named in the status bar.
    public func beginCompress() {
        guard pending == nil, planning == nil, !hasOpenField else { return }
        let sources = active.selectionEntries
        guard !sources.isEmpty else { return say("Move the cursor to a file, or mark some first.") }
        let other = panels[1 - activeIndex]
        guard !active.isInsideArchive, !other.isInsideArchive else { return say(OperationRefusal.readOnlyArchive.message) }
        // The archive would be built inside something it's reading.
        let destination = FileNames.realPath(other.location) ?? other.location.path
        let isInside = sources.contains { source in
            guard source.isDirectory, !source.isSymlink, let real = FileNames.realPath(source.url) else { return false }
            return destination == real || destination.hasPrefix(real + "/")
        }
        guard !isInside else { return say(OperationRefusal.folderIntoItself.message) }
        if viewer != nil { closeViewer() }
        let name = sources.count == 1 ? sources[0].name : active.location.lastPathComponent
        var draft = ArchiveDraft(name: name)
        if FileNames.exists(other.location.appending(path: draft.fileName)) {
            draft.name = FileNames.free(other.location.appending(path: draft.fileName)).lastPathComponent
            draft.name = String(draft.name.dropLast(draft.format.ext.count + 1))
        }
        pending = PendingOperation(
            preview: OperationPreview.compress(sources, to: other.location.appending(path: draft.fileName)),
            source: active, destination: other, choice: .replace, archive: draft
        )
        showPending(scroll: true)
    }

    public func updateArchive(_ draft: ArchiveDraft) {
        guard let current = pending, current.archive != nil, let folder = current.preview.folder else { return }
        let sources = current.preview.items.map(\.source)
        pending = PendingOperation(
            preview: OperationPreview.compress(sources, to: folder.appending(path: draft.name.isEmpty ? "untitled" : draft.fileName)),
            source: current.source, destination: current.destination, choice: current.choice, archive: draft
        )
        showPending(scroll: false)
    }

    /// What's stopping this compress, if anything.
    public var archiveProblem: String? {
        guard let draft = pending?.archive, let folder = pending?.preview.folder else { return nil }
        if let problem = FileNames.problem(with: draft.name) { return problem }
        return FileNames.exists(folder.appending(path: draft.fileName)) ? "\(draft.fileName) already exists there." : nil
    }

    /// Unpacks the selected archives into the other panel. Inside an archive, it takes out the selection.
    public func beginExtract() {
        if active.isInsideArchive { return begin(.extract) }
        let archives = active.selectionEntries.filter(\.isArchive)
        guard !archives.isEmpty else { return say("Move the cursor to an archive, or mark some first.") }
        begin(.extract, entries: archives)
    }

    public func cancelOperation() {
        pending?.source?.clearPreview()
        pending?.destination?.clearPreview()
        // The name field had focus and is going away, which would leave the keyboard with nothing.
        if pending?.archive != nil { returnFocus() }
        pending = nil
    }

    public func runOperation() {
        guard let pending, archiveProblem == nil else { return }
        cancelOperation()
        guard pending.preview.runCount(pending.choice) > 0 else {
            return say("Nothing to do: every item was skipped.")
        }
        pending.source?.unmark(pending.preview.items.map(\.source))
        jobs.add(pending.preview, choice: pending.choice)
    }

    public func dismissReport() {
        if !reports.isEmpty { reports.removeFirst() }
    }

    private func showPending(scroll: Bool) {
        guard let pending else { return }
        let (preview, choice) = (pending.preview, pending.choice)
        // Only these take the files away. Compress and extract leave the originals where they are.
        if [.move, .trash, .delete].contains(preview.kind) {
            let leaving = Dictionary(preview.items.map { (FileNames.key($0.source.url), RowPreview.leaving) }) { first, _ in first }
            pending.source?.showPreview(states: leaving, ghosts: [], kind: preview.kind, scroll: false)
        }
        guard let destination = pending.destination else { return }
        var states: [String: RowPreview] = [:]
        var ghosts: [FileEntry] = []
        for item in preview.items {
            guard let target = item.target else { continue }
            if let existing = item.existing, choice != .keepBoth {
                states[FileNames.key(target)] = choice == .skip ? .skipped
                    : existing.isDirectory ? .merging : .replacing(existing.age)
            } else if let final = preview.destination(of: item, choice) {
                let isCompress = preview.kind == .compress
                ghosts.append(FileEntry(
                    url: final, fileName: final.lastPathComponent, size: isCompress || item.source.isArchive ? nil : item.source.size,
                    modified: item.source.modified, isDirectory: item.unpacksArchive || (item.source.isDirectory && !isCompress),
                    isPackage: item.source.isPackage
                ))
                states[FileNames.key(final)] = .incoming
            }
        }
        destination.showPreview(states: states, ghosts: ghosts, kind: preview.kind, scroll: scroll)
    }

    // MARK: Viewer

    public var viewerIndex: Int { 1 - activeIndex }

    public func toggleViewer() {
        if viewer == nil {
            let opened = Viewer()
            opened.follow(active.cursorEntry)
            viewer = opened
        } else {
            closeViewer()
        }
    }

    public func closeViewer() {
        viewer = nil
        returnFocus()
    }

    // MARK: Compare and sync

    /// Compares the two panels' folders, left against right.
    public func beginCompare() {
        guard pending == nil, planning == nil, renameSession == nil, compareSession == nil, !hasOpenField else { return }
        let (left, right) = (panels[0], panels[1])
        guard !left.isInsideArchive, !right.isInsideArchive else { return say(OperationRefusal.readOnlyArchive.message) }
        guard let one = FileNames.realPath(left.location), let two = FileNames.realPath(right.location) else {
            return say("One of the folders can't be read.")
        }
        guard one != two else { return say("Both panels show the same folder.") }
        // A sync between them would copy a folder into itself. The root is inside nothing but holds everything.
        guard one != "/", two != "/", !one.hasPrefix(two + "/"), !two.hasPrefix(one + "/") else { return say("One panel's folder is inside the other's.") }
        if viewer != nil { closeViewer() }
        compareSession = CompareSession(left: left.location, right: right.location, showHidden: showHidden)
    }

    public func closeCompare() {
        compareSession?.stop()
        compareSession = nil
        returnFocus()
    }

    /// Runs what the compare screen shows. There's no other way in, so a sync can't skip its preview.
    public func runSync() {
        guard let session = compareSession, session.canSync, jobs.current == nil else { return }
        jobs.add(session.preview, choice: .replace)
    }

    // MARK: Multi-rename

    /// Opens on the marked files, or the cursor's. Folders are left out, but packages count as files.
    public func beginRename() {
        guard pending == nil, planning == nil, renameSession == nil, !hasOpenField else { return }
        let files = active.selectionEntries.filter { !$0.opensAsFolder }
        guard !active.isInsideArchive else { return say(OperationRefusal.readOnlyArchive.message) }
        guard !files.isEmpty else { return say("Mark the files to rename first.") }
        if viewer != nil { closeViewer() }
        renameSession = RenameSession(panel: active, files: files)
    }

    public func cancelRename() {
        renameSession = nil
        returnFocus()
    }

    public func runRename() {
        guard let session = renameSession, session.canRun else { return }
        cancelRename()
        // Marks stay for now. If this fails the set is still marked, and if not, the refresh drops them.
        jobs.add(session.preview, choice: .replace)
    }

    private func registerUndo(of renames: [FileRename]) {
        undoManager?.registerUndo(withTarget: self) { workspace in
            MainActor.assumeIsolated { workspace.reverse(renames) }
        }
        undoManager?.setActionName("Multi-Rename")
    }

    /// Runs in the queue like any rename, so it waits for a job using these files and shows its progress.
    /// Redo is registered here, because the undo manager only takes it during the undo.
    private func reverse(_ renames: [FileRename]) {
        let back = renames.map { FileRename(from: $0.to, to: $0.from) }
        registerUndo(of: back)
        let items = back.map { rename in
            let file = FileEntry(url: rename.from, fileName: rename.from.lastPathComponent, size: nil, modified: nil, isDirectory: false)
            return PlannedItem(source: file, target: rename.to, existing: nil)
        }
        var preview = OperationPreview(kind: .rename, folder: back.first?.to.deletingLastPathComponent(), items: items, alreadyThere: 0)
        preview.isUndo = true
        jobs.add(preview, choice: .replace)
    }

    // MARK: Palette

    public func openPalette() {
        guard renameSession == nil, compareSession == nil else { return }
        isPaletteOpen = true
    }

    public func closePalette() {
        isPaletteOpen = false
        returnFocus()
    }

    // MARK: Hand-offs

    public func edit() {
        guard let entry = active.cursorEntry, !entry.isParent, !entry.isDirectory else {
            return say("Move the cursor to a file to edit it.")
        }
        if active.isInsideArchive { return say(OperationRefusal.readOnlyArchive.message) }
        desktop.edit(entry.url)
    }

    public func openTerminal() {
        desktop.openTerminal(active.realFolder)
    }

    /// Copies the selection's paths, or the folder's if nothing is selected.
    public func copyPath() {
        let paths = active.selectionEntries.map(\.url.path)
        desktop.copyText((paths.isEmpty ? [active.location.path] : paths).joined(separator: "\n"))
        say(paths.count > 1 ? "Copied \(paths.count) paths." : "Copied the path.")
    }

    // MARK: Command line

    public func focusCommandLine() {
        commandLineTick += 1
    }

    /// `cd` moves the active panel. Anything else runs in its folder, and any output opens in the viewer.
    public func runCommandLine(_ line: String) {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let path = Self.cdTarget(text) {
            commandTask = Task {
                if let problem = await goTo(path: path) { say(problem) }
            }
            return
        }
        guard runningCommand == nil else { return say("A command is already running.") }
        let output = FileManager.default.temporaryDirectory.appending(path: "commander-output-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else {
            return say("The command couldn't start.")
        }
        let process = Process()
        process.executableURL = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // A login shell, because an app started from the Dock doesn't get the user's PATH.
        process.arguments = ["-lc", text]
        process.currentDirectoryURL = active.realFolder
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        self.process = process
        wasStopped = false
        runningCommand = text
        commandTask = Task {
            let status = await withCheckedContinuation { (finished: CheckedContinuation<Int32, Never>) in
                process.terminationHandler = { finished.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    finished.resume(returning: 127)
                }
            }
            try? handle.close()
            commandFinished(text, status: status, output: output)
        }
    }

    public func stopCommand() {
        guard let process, process.isRunning else { return }
        wasStopped = true
        process.terminate()
    }

    /// The folder a plain `cd` asks for. Anything using shell syntax is left to the shell.
    private static func cdTarget(_ text: String) -> String? {
        guard text == "cd" || text.hasPrefix("cd "),
              text.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|<>$`()*?")) == nil else { return nil }
        let path = text.dropFirst(2).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\ ", with: " ")
        return path.isEmpty ? "~" : path
    }

    /// Waits for a command line entry to finish, including cleanup when stopping.
    public func commandDone() async {
        await commandTask?.value
    }

    private func commandFinished(_ text: String, status: Int32, output: URL) {
        process = nil
        runningCommand = nil
        for panel in panels { panel.refresh() }
        say(wasStopped ? "Stopped \(text)." : status == 0 ? "Finished \(text)." : "\(text) exited with status \(status).")
        let size = (try? output.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 0, pending == nil {
            let shown = viewer ?? Viewer()
            // The viewer keeps the file open, so its name can go right away.
            shown.pin(output, title: "Output of \(text)", cursor: active.cursorEntry)
            viewer = shown
        }
        try? FileManager.default.removeItem(at: output)
    }

    // MARK: Inside archives

    /// Opens a file inside an archive by unpacking it somewhere temporary first.
    /// shortcut: the temporary copy stays until the system clears it. Track and remove these if they pile up.
    fileprivate func openInArchive(_ entry: FileEntry) {
        guard let place = ArchivePath.split(entry.url) else { return }
        let folder = FileManager.default.temporaryDirectory.appending(path: "commander-open-\(UUID().uuidString)", directoryHint: .isDirectory)
        let target = folder.appending(path: entry.fileName)
        say("Opening \(entry.fileName)…")
        Task {
            let problem = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                } catch {
                    return error.localizedDescription
                }
                do throws(OperationError) {
                    _ = try ArchiveExtractor().extract(place.archive, inner: place.inner, to: target, conflict: .skip)
                    return nil
                } catch {
                    return error.message
                }
            }.value
            if let problem { say(problem) } else { openFile(target) }
        }
    }

    // MARK: Clipboard

    /// Starts a copy or move of files from the clipboard into the active panel.
    public func paste(_ urls: [URL], move: Bool) {
        let entries = urls.compactMap(LocalSource.entry)
        begin(move ? .move : .copy, entries: entries, into: active.location)
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
    /// A row name being typed: a new folder, or a rename.
    public private(set) var edit: EditState?
    /// The kind of operation being previewed, which sets the colour of preview rows.
    public private(set) var previewKind: OperationKind?
    /// Bumped to ask the table to bring `scrollTarget` into view.
    public private(set) var scrollRequest = 0
    public private(set) var scrollTarget = 0

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
    @ObservationIgnored private var rowStates: [String: RowPreview] = [:]
    @ObservationIgnored private var ghosts: [FileEntry] = []
    @ObservationIgnored private var draftFolder: FileEntry?
    @ObservationIgnored private var cursorBeforeDraft: URL?

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

    /// Waits until the folder is loaded. Used by tests and at launch.
    /// It loops, because a change on disk can start a newer load that cancels the one being waited for.
    public func loaded() async {
        await loading?.value
        while isLoading {
            await Task.yield()
            await loading?.value
        }
    }

    public func refresh() {
        load(cursor: cursorEntry?.url)
    }

    /// Refreshes with the cursor staying on its file if a rename gave it a new name.
    func refresh(following renames: [FileRename]) {
        guard let cursor = cursorEntry?.url, let folder = renames.first?.from.deletingLastPathComponent(),
              FileNames.realPath(folder) == FileNames.realPath(location) else { return refresh() }
        // By name, because one folder can have several paths.
        let key = FileNames.key(cursor)
        load(cursor: renames.first { FileNames.key($0.from) == key }?.to ?? cursor)
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
            if let notice = listing.notice { workspace?.say(notice) }
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
            // A load still running finishes first. Cancelling it would mean that in a folder
            // being written to, a listing slower than this delay never completes at all.
            await loading?.value
            if !Task.isCancelled { load(cursor: cursorEntry?.url, followMissing: true) }
        }
    }

    /// Rebuilds rows from the listing. The cursor stays on its file, or at the same position if that file went.
    func rebuildRows(cursor: URL? = nil) {
        let keep = cursor ?? cursorEntry?.url
        let previous = cursorIndex
        rows = tab.rows(showHidden: workspace?.showHidden ?? false)
        mergePreviewRows()
        cursorIndex = keep.flatMap(row(for:)) ?? min(previous, max(rows.count - 1, 0))
        rowsVersion += 1
        // Marks can't outlive their row, so nothing unseen is ever acted on, such as a file that was just hidden.
        if !tab.marked.isEmpty {
            tabs[tabIndex].marked.formIntersection(rows.map(\.url.path))
        }
        refreshMarks()
    }

    /// Rows match by name, because one folder can have several paths: /tmp is also /private/tmp.
    /// The ".." row goes first, or a file named like the parent folder would take its place.
    private func row(for url: URL) -> Int? {
        if rows.first?.isParent == true, rows[0].url.path == url.path { return 0 }
        let key = FileNames.key(url)
        return rows.firstIndex { !$0.isParent && FileNames.key($0.url) == key }
    }

    /// Ghosts are placed by binary search, so a preview doesn't re-sort a huge folder,
    /// and the rows are rebuilt once, so a big preview doesn't shift them for every ghost.
    private func mergePreviewRows() {
        let start = tab.parent == nil ? 0 : 1
        if let draftFolder { rows.insert(draftFolder, at: start) }
        guard !ghosts.isEmpty else { return }
        var merged = Array(rows[..<start])
        merged.reserveCapacity(rows.count + ghosts.count)
        var next = start
        for ghost in ghosts.sorted(by: tab.sort.precedes) {
            var low = next
            var high = rows.count
            while low < high {
                let middle = (low + high) / 2
                if tab.sort.precedes(rows[middle], ghost) { low = middle + 1 } else { high = middle }
            }
            merged += rows[next..<low]
            merged.append(ghost)
            next = low
        }
        rows = merged + rows[next...]
    }

    // MARK: Operation previews

    public func previewState(of entry: FileEntry) -> RowPreview? {
        rowStates.isEmpty || entry.isParent ? nil : rowStates[FileNames.key(entry.url)]
    }

    func showPreview(states: [String: RowPreview], ghosts: [FileEntry], kind: OperationKind, scroll: Bool) {
        rowStates = states
        self.ghosts = ghosts
        previewKind = kind
        rebuildRows()
        guard scroll else { return }
        // A replacement matters most, so it's what the preview brings into view.
        let first = rows.firstIndex { if case .replacing = previewState(of: $0) { true } else { false } }
        if let row = first ?? rows.firstIndex(where: { previewState(of: $0) != nil }) {
            scrollTarget = row
            scrollRequest += 1
        }
    }

    func clearPreview() {
        guard previewKind != nil else { return }
        rowStates = [:]
        ghosts = []
        previewKind = nil
        rebuildRows()
    }

    /// The marked rows, or else the cursor's row.
    public var selectionEntries: [FileEntry] {
        if tab.marked.isEmpty {
            return cursorEntry.flatMap { $0.isParent ? nil : [$0] } ?? []
        }
        return rows.filter { tab.marked.contains($0.url.path) }
    }

    // MARK: New folders and renames

    /// True while showing the inside of an archive, which can be read but not changed.
    public var isInsideArchive: Bool { ArchivePath.split(location) != nil }

    /// Somewhere that really exists on disk: the folder holding the archive, if inside one.
    var realFolder: URL { ArchivePath.split(location)?.archive.deletingLastPathComponent() ?? location }

    public func beginNewFolder() {
        guard tab.failure == nil, edit == nil, workspace?.pending == nil else { return }
        guard !isInsideArchive else { workspace?.say(OperationRefusal.readOnlyArchive.message); return }
        let url = FileNames.freeFolder(in: location)
        let draft = FileEntry(url: url, fileName: url.lastPathComponent, size: nil, modified: nil, isDirectory: true)
        draftFolder = draft
        cursorBeforeDraft = cursorEntry?.url
        rebuildRows(cursor: url)
        edit = EditState(kind: .newFolder, text: draft.name)
    }

    public func beginRename() {
        guard let entry = cursorEntry, !entry.isParent, edit == nil, workspace?.pending == nil else { return }
        guard !isInsideArchive else { workspace?.say(OperationRefusal.readOnlyArchive.message); return }
        edit = EditState(kind: .rename(entry.url), text: entry.fileName)
    }

    public func cancelEdit() {
        edit = nil
        if draftFolder != nil {
            draftFolder = nil
            rebuildRows(cursor: cursorBeforeDraft)
        }
    }

    /// Finishes typing a name. On success it returns any rename made, so it can be undone.
    public func commitEdit(_ text: String) throws(EditFailure) -> FileRename? {
        guard let state = edit else { return nil }
        if let problem = FileNames.problem(with: text) { throw EditFailure(message: problem) }
        let target = location.appending(path: text)
        switch state.kind {
        case .newFolder:
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } catch {
                throw EditFailure(message: "\(text) already exists here, or this folder can't be changed.")
            }
            cancelEdit()
            load(cursor: target)
            return nil
        case .rename(let source):
            guard source.lastPathComponent != text else {
                cancelEdit()
                return nil
            }
            do throws(OperationError) {
                try FileNames.rename(source, to: target)
            } catch {
                throw EditFailure(message: error == .alreadyExists ? "\(text) already exists here." : error.message)
            }
            cancelEdit()
            load(cursor: target)
            return FileRename(from: source, to: target)
        }
    }

    /// Reverses a rename. Returns the rename that undoes it, for redo.
    public func undo(_ rename: FileRename) throws(OperationError) -> FileRename {
        try FileNames.rename(rename.to, to: rename.from)
        load(cursor: rename.from)
        return FileRename(from: rename.to, to: rename.from)
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
        // A name being typed belongs to the folder it was started in.
        if edit != nil {
            cancelEdit()
            workspace?.returnFocus()
        }
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
        } else if entry.opensAsFolder || (asFolder && entry.isDirectory) || (!isInsideArchive && entry.isArchive) {
            navigate(to: entry.url)
        } else if isInsideArchive {
            workspace?.openInArchive(entry)
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

    func unmark(_ entries: [FileEntry]) {
        tabs[tabIndex].marked.subtract(entries.map(\.url.path))
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
