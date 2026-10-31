import Foundation

/// One entry in the command palette.
public struct AppCommand: Identifiable {
    public let title: String
    public let keys: String
    public let symbol: String
    public let isEnabled: Bool
    public let run: @MainActor () -> Void

    public let id: String

    /// `id` is needed only where a title can repeat, as two drives can share a name.
    init(_ title: String, _ keys: String, _ symbol: String, enabled: Bool = true, id: String? = nil, run: @escaping @MainActor () -> Void) {
        self.id = id ?? title
        self.title = title
        self.keys = keys
        self.symbol = symbol
        isEnabled = enabled
        self.run = run
    }
}

/// What only the app itself can do. The core asks, and stays free of UI imports.
@MainActor
public struct Desktop {
    public var edit: (URL) -> Void = { _ in }
    public var openTerminal: (URL) -> Void = { _ in }
    public var copyText: (String) -> Void = { _ in }
    public var copyFiles: ([URL]) -> Void = { _ in }
    public var pastedFiles: () -> [URL] = { [] }
    public var quickLook: () -> Void = {}
    public var showActions: () -> Void = {}
    public var undo: () -> Void = {}
    public var openFullDiskAccess: () -> Void = {}

    public nonisolated init() {}
}

extension Workspace {
    /// Commands whose title or keys hold every typed word, with title matches at the start listed first.
    public func commands(matching query: String) -> [AppCommand] {
        let all = commands
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return all }
        let hits = all.filter { command in
            let text = "\(command.title) \(command.keys)".lowercased()
            return words.allSatisfy(text.contains)
        }
        let first = query.lowercased()
        return hits.filter { $0.title.lowercased().hasPrefix(first) } + hits.filter { !$0.title.lowercased().hasPrefix(first) }
    }

    /// Everything the app can do. A feature that lands in a later milestone adds its command here.
    public var commands: [AppCommand] {
        let panel = active
        // The palette itself counts as typing, but it closes before a command runs.
        let idle = isPaletteOpen || !isTyping
        let chosen = panel.selectionCount > 0 && idle
        var list = [
            AppCommand("View Beside", "F3 or ⌘Y", "eye") { [self] in toggleViewer() },
            AppCommand("Show as Text or Hex", "⌘⇧H", "number", enabled: viewer != nil) { [self] in viewer?.toggleHex() },
            AppCommand("Quick Look", "⇧F3 or ⌘⇧Y", "eye.circle") { [self] in desktop.quickLook() },
            AppCommand("Edit", "F4 or ⌘E", "pencil") { [self] in edit() },
            AppCommand("Copy to Other Panel", "F5 or ⌘⇧C", "doc.on.doc", enabled: chosen) { [self] in begin(.copy) },
            AppCommand("Move to Other Panel", "F6 or ⌘⇧M", "arrow.right", enabled: chosen) { [self] in begin(.move) },
            AppCommand("New Folder", "F7 or ⌘⇧N", "plus", enabled: idle) { panel.beginNewFolder() },
            AppCommand("Move to Trash", "F8 or ⌘⌫", "trash", enabled: chosen) { [self] in begin(.trash) },
            AppCommand("Delete Permanently", "⇧F8 or ⌥⌘⌫", "trash.slash", enabled: chosen) { [self] in begin(.delete) },
            AppCommand("Rename", "⇧F6 or ⌥⌘R", "character.cursor.ibeam", enabled: idle) { panel.beginRename() },
            AppCommand("Multi-Rename", "⌘⇧R", "text.cursor", enabled: chosen) { [self] in beginRename() },
            AppCommand("Undo Rename", "⌘Z", "arrow.uturn.backward") { [self] in desktop.undo() },
            AppCommand("Show Actions", "⇧F10 or ⌥⌘M", "ellipsis.circle") { [self] in desktop.showActions() },
            AppCommand("Copy Files", "⌘C", "doc.on.clipboard", enabled: chosen) { [self] in
                desktop.copyFiles(panel.selectionEntries.map(\.url))
            },
            AppCommand("Paste Files", "⌘V", "doc.on.clipboard.fill", enabled: idle) { [self] in paste(desktop.pastedFiles(), move: false) },
            AppCommand("Compress to Other Panel", "⌘⇧P", "archivebox", enabled: chosen) { [self] in beginCompress() },
            AppCommand("Extract to Other Panel", "⌘⇧U", "archivebox.fill", enabled: chosen) { [self] in beginExtract() },
            AppCommand("Compare and Sync", "⌘⇧D", "rectangle.split.2x1") { [self] in beginCompare() },
            AppCommand("Move Here", "⌥⌘V", "arrow.down.doc", enabled: idle) { [self] in paste(desktop.pastedFiles(), move: true) },
            AppCommand("Copy Path", "⌥⌘C", "link") { [self] in copyPath() },
            AppCommand("Open Terminal Here", "⌘⇧T", "terminal") { [self] in openTerminal() },
            AppCommand("Go to Command Line", "⌘L", "chevron.right") { [self] in focusCommandLine() },
            AppCommand("Stop Job", "", "stop", enabled: jobs.current != nil) { [self] in jobs.stopCurrent() },
            AppCommand("Stop Command", "", "stop", enabled: runningCommand != nil) { [self] in stopCommand() },
            AppCommand("Mark or Unmark", "Space", "checkmark.circle") { panel.toggleMark() },
            AppCommand("Mark All", "⌘A", "checkmark.circle.fill") { panel.markAll() },
            AppCommand("Invert Marks", "*", "circle.lefthalf.filled") { panel.invertMarks() },
            AppCommand("Clear Marks", "Esc", "circle") { panel.clearMarks() },
            AppCommand("Mark by Pattern", "+", "plus.circle") { [self] in beginPattern(marks: true) },
            AppCommand("Unmark by Pattern", "-", "minus.circle") { [self] in beginPattern(marks: false) },
            AppCommand("Back", "⌘[", "chevron.left", enabled: panel.canGoBack) { panel.goBack() },
            AppCommand("Forward", "⌘]", "chevron.right", enabled: panel.canGoForward) { panel.goForward() },
            AppCommand("Enclosing Folder", "⌘↑", "arrow.up") { panel.goUp() },
            AppCommand("Open as Folder", "⌘↓", "arrow.down") { panel.openCursor(asFolder: true) },
            AppCommand("Go to Path", "⌘⇧G", "folder") { [self] in beginGoTo() },
            AppCommand("Switch Panel", "Tab", "arrow.left.arrow.right") { [self] in switchPanel() },
            AppCommand("New Tab", "⌘T", "plus.square") { panel.newTab() },
            AppCommand("Close Tab", "⌘W", "xmark.square", enabled: panel.tabs.count > 1) { panel.closeTab() },
            AppCommand("Next Tab", "⌘⇧]", "chevron.right.square") { panel.nextTab(by: 1) },
            AppCommand("Previous Tab", "⌘⇧[", "chevron.left.square") { panel.nextTab(by: -1) },
            AppCommand("Sort by Name", "⌃⌘1", "arrow.up.arrow.down") { panel.sort(by: .name) },
            AppCommand("Sort by Extension", "⌃⌘2", "arrow.up.arrow.down") { panel.sort(by: .ext) },
            AppCommand("Sort by Size", "⌃⌘3", "arrow.up.arrow.down") { panel.sort(by: .size) },
            AppCommand("Sort by Modified", "⌃⌘4", "arrow.up.arrow.down") { panel.sort(by: .modified) },
            AppCommand(showHidden ? "Hide Hidden Files" : "Show Hidden Files", "⌘⇧.", "eye.slash") { [self] in toggleHidden() },
            AppCommand("Refresh", "⌘R", "arrow.clockwise") { panel.refresh() },
            AppCommand("Open Full Disk Access Settings", "", "lock.open") { [self] in desktop.openFullDiskAccess() },
        ]
        for place in Places.favorites() + volumes {
            list.append(AppCommand("Go to \(place.title)", "", "folder", id: place.url.path) { panel.navigate(to: place.url) })
        }
        return list
    }
}
