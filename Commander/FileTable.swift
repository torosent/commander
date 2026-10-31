import AppKit
import CommanderCore
import Quartz
import SwiftUI

/// The file list. `NSTableView` only builds the rows on screen, so folder size barely affects it.
struct FileTable: NSViewRepresentable {
    static let rowHeight: CGFloat = 20

    let workspace: Workspace
    let index: Int
    let rows: [FileEntry]
    let version: Int
    let marksVersion: Int
    let cursor: Int
    let isActive: Bool
    let focusTick: Int
    let scrollRequest: Int
    let edit: EditState?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = KeyTable()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = Self.rowHeight
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.backgroundColor = Palette.deck
        table.gridStyleMask = []
        table.focusRingType = .none
        table.selectionHighlightStyle = .none
        table.allowsTypeSelect = false
        // Keeps Edit > Select All enabled, which arrives here as `selectAll` and marks every row.
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (column, width) in Column.allCases.map({ ($0, $0.width) }) {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.width = width
            tableColumn.resizingMask = []
            table.addTableColumn(tableColumn)
        }
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: false)

        let scroll = NSScrollView()
        scroll.contentView = RowSnappingClipView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalLineScroll = Self.rowHeight
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        fileprivate weak var table: KeyTable?
        private var rows: [FileEntry] = []
        private var version = -1
        private var marksVersion = -1
        private var cursor = 0
        private var isActive = false
        private var focusTick = -1
        private var hasActiveFocus = false
        private var location: URL?
        private var onSelect: (Int) -> Void = { _ in }
        private var isMarked: (FileEntry) -> Bool = { _ in false }
        private var view: FileTable?
        private var scrollRequest = 0
        private var editor: NSTextField?
        private var isFinishingEdit = false

        func update(_ view: FileTable) {
            guard let table else { return }
            self.view = view
            // A new table has no window on its first update, which mustn't clear the manager.
            if let manager = table.undoManager { view.workspace.undoManager = manager }
            onSelect = { [workspace = view.workspace, index = view.index] row in
                workspace.activate(index)
                workspace.panels[index].setCursor(row)
            }
            table.onKey = { [weak table] event in view.handle(event, page: table?.visibleRows ?? 1) }
            table.onClick = { row, clicks in view.click(row: row, count: clicks) }
            table.onMarkAll = { view.workspace.panels[view.index].markAll() }
            table.onCopy = { view.copyToPasteboard() }
            table.onPaste = { view.workspace.paste(Pasteboard.fileURLs(), move: false) }
            table.onMenu = { [weak table] row in table.flatMap { view.menu(row: row, in: $0) } }
            table.dragURLs = { row in view.dragURLs(row: row) }
            table.quickLookURL = { [panel = view.workspace.panels[view.index]] in
                panel.isInsideArchive ? nil : panel.cursorEntry.flatMap { $0.isParent ? nil : $0.url }
            }
            isMarked = { [panel = view.workspace.panels[view.index]] in panel.isMarked($0) }
            table.setAccessibilityLabel("\(view.workspace.panels[view.index].tab.title) files")

            if view.version != version {
                let panel = view.workspace.panels[view.index]
                let shownFile = rows.indices.contains(cursor) ? rows[cursor].url : nil
                let newFile = view.rows.indices.contains(view.cursor) ? view.rows[view.cursor].url : nil
                // A refresh must not pull away someone who has scrolled from the cursor.
                let follow = panel.location != location || newFile != shownFile
                    || table.rows(in: table.visibleRect).contains(cursor)
                location = panel.location
                version = view.version
                rows = view.rows
                cursor = view.cursor
                isActive = view.isActive
                table.reloadData()
                if follow { table.scrollRowToVisible(cursor) }
            } else if view.cursor != cursor || view.isActive != isActive {
                let changed = IndexSet([cursor, view.cursor].filter(rows.indices.contains))
                cursor = view.cursor
                isActive = view.isActive
                table.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(table.tableColumns.indices))
                for row in changed { configure(table.rowView(atRow: row, makeIfNecessary: false) as? CursorRowView, row) }
                table.scrollRowToVisible(cursor)
                table.refreshQuickLook()
            }
            if view.marksVersion != marksVersion {
                marksVersion = view.marksVersion
                let visible = table.rows(in: table.visibleRect)
                table.reloadData(
                    forRowIndexes: IndexSet(integersIn: Range(visible) ?? 0..<0),
                    columnIndexes: IndexSet(table.tableColumns.indices)
                )
            }
            if view.scrollRequest != scrollRequest {
                scrollRequest = view.scrollRequest
                table.scrollRowToVisible(view.workspace.panels[view.index].scrollTarget)
            }
            updateEditor(view.edit, in: table)
            // The selection mirrors the cursor, so VoiceOver reads the row and can move it.
            if table.selectedRow != cursor, rows.indices.contains(cursor) {
                table.selectRowIndexes([cursor], byExtendingSelection: false)
            }
            // Only an explicit hand-over takes focus, or typing in a field would lose it on every refresh.
            if isActive, view.focusTick != focusTick || !hasActiveFocus {
                table.takeFocus()
            }
            focusTick = view.focusTick
            hasActiveFocus = isActive
        }

        private func configure(_ view: CursorRowView?, _ row: Int) {
            view?.isCursor = row == cursor
            view?.isActivePanel = isActive
        }

        private func updateEditor(_ edit: EditState?, in table: KeyTable) {
            guard let edit else {
                editor?.removeFromSuperview()
                editor = nil
                return
            }
            let row = cursor
            table.scrollRowToVisible(row)
            let frame = table.rect(ofRow: row)
            let box = table.convert(
                NSRect(x: 37, y: frame.minY + 1, width: max(table.tableColumns[0].width - 45, 80), height: 18),
                to: table.enclosingScrollView
            )
            if let editor {
                editor.frame = box
                return
            }
            let field = NSTextField(string: edit.text)
            field.frame = box
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.textColor = Palette.ink
            field.backgroundColor = Palette.deck
            field.drawsBackground = true
            field.focusRingType = .none
            field.delegate = self
            field.setAccessibilityLabel("Name")
            // In the scroll view, not the table: a table only exposes its rows, so VoiceOver couldn't reach it.
            // shortcut: the field doesn't follow a mouse-wheel scroll during an edit. Fix if that proves annoying.
            field.wantsLayer = true
            field.layer?.zPosition = 10
            table.enclosingScrollView?.addSubview(field, positioned: .above, relativeTo: nil)
            editor = field
            // SwiftUI is mid-update here and would undo a focus change, so this waits a turn.
            DispatchQueue.main.async { [weak field] in
                guard let field else { return }
                field.window?.makeFirstResponder(field)
                // The name is selected without its extension, as in Finder.
                let (name, _) = FileEntry.nameParts(edit.text)
                field.currentEditor()?.selectedRange = NSRange(location: 0, length: (name as NSString).length)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                finishEdit(committing: true, staysOpenOnFailure: true)
            case #selector(NSResponder.cancelOperation(_:)):
                finishEdit(committing: false, staysOpenOnFailure: false)
            default:
                return false
            }
            return true
        }

        /// Clicking away saves the name, as in Finder.
        func controlTextDidEndEditing(_ notification: Notification) {
            finishEdit(committing: true, staysOpenOnFailure: false)
        }

        private func finishEdit(committing: Bool, staysOpenOnFailure: Bool) {
            guard !isFinishingEdit, let view, let editor else { return }
            isFinishingEdit = true
            defer { isFinishingEdit = false }
            let panel = view.workspace.panels[view.index]
            if committing {
                do throws(EditFailure) {
                    if let rename = try panel.commitEdit(editor.stringValue) { registerUndo(rename, panel, view.workspace) }
                } catch {
                    view.workspace.say(error.message)
                    if staysOpenOnFailure { return }
                    panel.cancelEdit()
                }
            } else {
                panel.cancelEdit()
            }
            view.workspace.returnFocus()
        }

        private func registerUndo(_ rename: FileRename, _ panel: Panel, _ workspace: Workspace) {
            guard let manager = table?.undoManager else { return }
            manager.registerUndo(withTarget: panel) { [weak self] panel in
                MainActor.assumeIsolated {
                    do throws(OperationError) {
                        let reverse = try panel.undo(rename)
                        self?.registerUndo(reverse, panel, workspace)
                    } catch {
                        workspace.say(error.message)
                    }
                }
            }
            manager.setActionName("Rename")
        }

        // MARK: Drops

        func tableView(
            _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
            proposedDropOperation operation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard let view, view.workspace.pending == nil else { return [] }
            if rows.indices.contains(row), operation == .on, rows[row].opensAsFolder {
                tableView.setDropRow(row, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            let operation = view.dropOperation(info)
            // Holding ⌘ narrows the mask to generic, which a specific answer would fall outside.
            return info.draggingSourceOperationMask.contains(operation) ? operation : .generic
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard let view else { return false }
            let urls = Pasteboard.fileURLs(info.draggingPasteboard)
            let folder = rows.indices.contains(row) ? rows[row].url : view.workspace.panels[view.index].location
            // A drop only starts a preview, so it can still be cancelled.
            view.workspace.activate(view.index)
            view.workspace.begin(
                view.dropOperation(info) == .move ? .move : .copy,
                entries: urls.compactMap(LocalSource.entry), into: folder
            )
            return true
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, table.selectedRow >= 0, table.selectedRow != cursor else { return }
            onSelect(table.selectedRow)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = CursorRowView()
            configure(view, row)
            view.wash = self.view.flatMap { RowStyle($0.workspace.panels[$0.index], rows[row])?.wash }
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, let kind = Column(rawValue: column.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? FileCell ?? FileCell(kind)
            cell.identifier = column.identifier
            let style = view.flatMap { RowStyle($0.workspace.panels[$0.index], rows[row]) }
            cell.show(rows[row], isCursor: row == cursor && isActive, isMarked: isMarked(rows[row]), style: style)
            return cell
        }
    }

    /// While a preview waits, only its own keys work, so nothing changes what's being confirmed.
    private func handlePending(_ event: NSEvent, _ pending: PendingOperation) -> Bool {
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (event.keyCode, key) {
        case (53, _): workspace.cancelOperation()
        case (36, _), (76, _):
            if pending.preview.kind != .delete { workspace.runOperation() }
        case (_, "d"):
            if pending.preview.kind == .delete { workspace.runOperation() }
        case (_, "r"): workspace.choose(.replace)
        case (_, "s"): workspace.choose(.skip)
        case (_, "k"): workspace.choose(.keepBoth)
        default: break
        }
        return true
    }

    private func handle(_ event: NSEvent, page: Int) -> Bool {
        let panel = workspace.panels[index]
        if let pending = workspace.pending { return handlePending(event, pending) }
        if workspace.report != nil, event.keyCode == 53 {
            workspace.dismissReport()
            return true
        }
        let shifted = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case 125: panel.moveCursor(by: 1)
        case 126: panel.moveCursor(by: -1)
        case 121: panel.moveCursor(by: page)
        case 116: panel.moveCursor(by: -page)
        case 119: panel.setCursor(.max - 1)
        case 115: panel.setCursor(0)
        case 36, 76:
            // After No match the cursor is on an unrelated row, so Return must not open it.
            guard !panel.queryFailed else { break }
            panel.endSearch()
            panel.openCursor()
        case 51:
            if !panel.eraseSearch() { panel.goUp() }
        case 48:
            panel.endSearch()
            workspace.switchPanel()
        case 49: panel.markOrExtendSearch()
        case 53:
            if workspace.patternBar != nil {
                workspace.cancelPattern()
            } else if panel.query.isEmpty {
                panel.clearMarks()
            } else {
                panel.endSearch()
            }
        case 99:
            if shifted { QuickLook.toggle() } else { workspace.toggleViewer() }
        case 118: workspace.edit()
        case 96: workspace.begin(.copy)
        case 97:
            if shifted { panel.beginRename() } else { workspace.begin(.move) }
        case 98: panel.beginNewFolder()
        case 100: workspace.begin(shifted ? .delete : .trash)
        case 109 where shifted: NSApp.sendAction(#selector(KeyTable.showActions(_:)), to: nil, from: nil)
        default: return typed(event, panel)
        }
        return true
    }

    /// Printable keys find a file. With no search running, `+` `-` and `*` mark instead.
    private func typed(_ event: NSEvent, _ panel: Panel) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]),
              let text = event.characters, let scalar = text.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar),
              !(0xF700...0xF8FF).contains(scalar.value) // AppKit's range for function keys
        else { return false }
        if panel.query.isEmpty {
            switch text {
            case "+", "=": workspace.beginPattern(marks: true)
            case "-": workspace.beginPattern(marks: false)
            case "*": panel.invertMarks()
            default: panel.search(typing: text)
            }
        } else {
            panel.search(typing: text)
        }
        return true
    }

    private func click(row: Int, count: Int) {
        guard workspace.pending == nil else { return }
        workspace.activate(index)
        workspace.returnFocus()
        guard row >= 0 else { return }
        let panel = workspace.panels[index]
        panel.setCursor(row)
        if count == 2 { panel.openCursor() }
    }
}

extension FileTable {
    func copyToPasteboard() {
        let panel = workspace.panels[index]
        guard !panel.isInsideArchive else { return workspace.say("Copy files out of an archive with F5.") }
        let urls = panel.selectionEntries.map(\.url)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls as [NSURL])
    }

    /// A marked row drags all the marks. Any other row drags alone.
    func dragURLs(row: Int) -> [URL] {
        let panel = workspace.panels[index]
        // A file inside an archive has no path anything else could open.
        guard panel.rows.indices.contains(row), !panel.rows[row].isParent, workspace.pending == nil, !panel.isInsideArchive else { return [] }
        let entry = panel.rows[row]
        return panel.isMarked(entry) ? panel.selectionEntries.map(\.url) : [entry.url]
    }

    /// Finder's rule: move within a volume and copy between them. ⌥ forces a copy and ⌘ forces a move.
    func dropOperation(_ info: any NSDraggingInfo) -> NSDragOperation {
        let held = NSEvent.modifierFlags
        if held.contains(.option) { return .copy }
        if held.contains(.command) { return .move }
        guard let first = Pasteboard.fileURLs(info.draggingPasteboard).first else { return [] }
        let volume = { (url: URL) in (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject }
        return volume(first) == volume(workspace.panels[index].location) ? .move : .copy
    }

    /// Acts on the clicked row, or on all the marks if that row is one of them.
    func menu(row: Int, in table: NSTableView) -> NSMenu? {
        let panel = workspace.panels[index]
        guard panel.rows.indices.contains(row), workspace.pending == nil else { return nil }
        let entry = panel.rows[row]
        guard !entry.isParent else { return nil }
        workspace.activate(index)
        panel.setCursor(row)
        let isMany = panel.isMarked(entry) && panel.markedCount > 1
        let entries = isMany ? panel.selectionEntries : [entry]

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.add("Open") { panel.openCursor() }
        if !entry.isDirectory { menu.addItem(openWith(entry.url)) }
        menu.add("Quick Look", action: QuickLook.toggle)
        menu.addItem(.separator())
        if isMany { menu.addItem(.sectionHeader(title: "\(entries.count) Marked Items")) }
        menu.add("Copy to Other Panel") { workspace.begin(.copy, entries: entries) }
        if !panel.isInsideArchive {
            menu.add("Move to Other Panel") { workspace.begin(.move, entries: entries) }
            menu.add("Compress") { workspace.beginCompress() }
        }
        if panel.isInsideArchive || entries.contains(where: \.isArchive) {
            menu.add("Extract to Other Panel", action: workspace.beginExtract)
        }
        guard !panel.isInsideArchive else { return menu }
        menu.add("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(entries.map(\.url) as [NSURL])
        }
        if isMany {
            menu.add("Multi-Rename", action: workspace.beginRename)
        } else {
            menu.add("Rename") { panel.beginRename() }
        }
        menu.addItem(.separator())
        menu.add("Move to Trash") { workspace.begin(.trash, entries: entries) }
        return menu
    }

    private func openWith(_ url: URL) -> NSMenuItem {
        let item = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let apps = NSMenu()
        apps.autoenablesItems = false
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(12) {
            apps.add(FileManager.default.displayName(atPath: app.path)) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        item.submenu = apps
        return item
    }
}

extension NSMenu {
    /// Adds an item that runs a closure. The item keeps the closure alive.
    fileprivate func add(_ title: String, action: @escaping () -> Void) {
        let item = ClosureMenuItem(title: title, run: action)
        addItem(item)
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("Not used") }

    @objc private func fire() {
        run()
    }
}

enum Pasteboard {
    static func fileURLs(_ pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

/// How a row looks during a preview. Colour says what will happen, and the tag and icon say it again.
private struct RowStyle {
    var wash: NSColor?
    var ink: NSColor
    var tag: String?
    var symbol: String?

    @MainActor
    init?(_ panel: Panel, _ entry: FileEntry) {
        guard let state = panel.previewState(of: entry) else { return nil }
        let isMove = panel.previewKind == .move
        let (flow, flowInk) = isMove ? (Palette.moveWash, Palette.moveText) : (Palette.goWash, Palette.goText)
        switch state {
        case .incoming:
            (wash, ink, symbol) = (flow, flowInk, "plus")
        case .merging:
            (wash, ink, tag, symbol) = (flow, flowInk, "merges", "plus")
        case .replacing(let age):
            let note = switch age {
            case .older: "replaces older"
            case .same: "replaces"
            case .newer: "replaces newer"
            }
            (wash, ink, tag, symbol) = (Palette.removeWash, Palette.removeText, note, "exclamationmark.triangle")
        case .skipped:
            (ink, tag) = (Palette.dim, "skipped")
        case .leaving:
            let trashing = panel.previewKind != .move
            wash = trashing ? Palette.removeWash : Palette.moveWash
            ink = trashing ? Palette.removeText : Palette.moveText
            symbol = trashing ? "trash" : "arrow.right"
        }
    }
}

private enum Column: String, CaseIterable {
    case name, ext, size, modified

    var identifier: NSUserInterfaceItemIdentifier { .init(rawValue) }

    /// Matches the header in `PanelView`. Modified includes the 8pt trailing inset.
    var width: CGFloat {
        switch self {
        case .name: 400
        case .ext: 96
        case .size: 84
        case .modified: 114
        }
    }
}

final class KeyTable: NSTableView {
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move, .generic]
    }

    var onKey: (NSEvent) -> Bool = { _ in false }
    var onClick: (Int, Int) -> Void = { _, _ in }
    var onMarkAll: () -> Void = {}
    var quickLookURL: () -> URL? = { nil }
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onMenu: (Int) -> NSMenu? = { _ in nil }
    var dragURLs: (Int) -> [URL] = { _ in [] }
    private var wantsFocus = false
    private var dragStart: (row: Int, event: NSEvent)?

    func takeFocus() {
        wantsFocus = window == nil
        window?.makeFirstResponder(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus { takeFocus() }
    }

    /// The name column takes whatever the fixed columns leave, so every column stays on screen.
    func fitColumns(to width: CGFloat) {
        let fixed = tableColumns.dropFirst().reduce(0) { $0 + $1.width }
        tableColumns.first?.width = max(width - fixed, 100)
    }

    var visibleRows: Int {
        max(Int((enclosingScrollView?.contentView.bounds.height ?? 0) / FileTable.rowHeight), 1)
    }

    override func selectAll(_ sender: Any?) {
        onMarkAll()
    }

    override func keyDown(with event: NSEvent) {
        if onKey(event) { return }
        // Unbound plain keys stay silent rather than beep.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if !modifiers.isEmpty { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        dragStart = (row, event)
        onClick(row, event.clickCount)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let point = convert(start.event.locationInWindow, from: nil)
        let frame = NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)
        let items = dragURLs(start.row).map { url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(frame, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: start.event, source: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onMenu(row(at: convert(event.locationInWindow, from: nil)))
    }

    @objc func showActions(_ sender: Any?) {
        guard let menu = onMenu(selectedRow) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 40, y: rect(ofRow: selectedRow).maxY), in: self)
    }

    @objc func copy(_ sender: Any?) {
        onCopy()
    }

    @objc func paste(_ sender: Any?) {
        onPaste()
    }
}

@MainActor
enum QuickLook {
    /// Goes through the responder chain, so it reaches whichever table has focus.
    static func toggle() {
        NSApp.sendAction(#selector(KeyTable.toggleQuickLook(_:)), to: nil, from: nil)
    }
}

extension KeyTable: @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    @objc func toggleQuickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else if quickLookURL() != nil {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func refreshQuickLook() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        QLPreviewPanel.shared().reloadData()
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    // AppKit calls these two on the main thread, but they're declared without isolation.
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookURL() == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        quickLookURL() as NSURL?
    }

    /// Only cursor keys reach the table. Others stay with Quick Look, so Esc closes it rather than clearing marks.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        if event.keyCode == 99 {
            panel.orderOut(nil)
            return true
        }
        guard [125, 126, 121, 116, 119, 115].contains(event.keyCode) else { return false }
        keyDown(with: event)
        return true
    }
}

/// Scrolling stops on whole rows, so a row is never clipped at the top.
private final class RowSnappingClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        bounds.origin.y = (bounds.origin.y / FileTable.rowHeight).rounded() * FileTable.rowHeight
        return bounds
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        (documentView as? KeyTable)?.fitColumns(to: newSize.width)
    }
}

private final class CursorRowView: NSTableRowView {
    var isCursor = false { didSet { needsDisplay = true } }
    var isActivePanel = false { didSet { needsDisplay = true } }
    var wash: NSColor?

    override var isTargetForDropOperation: Bool {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if let wash {
            wash.setFill()
            bounds.fill(using: .sourceOver)
        }
        if isTargetForDropOperation {
            Palette.ink.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        guard isCursor else { return }
        if isActivePanel {
            Palette.cursor.setFill()
            bounds.fill()
        } else {
            Palette.dim.setStroke()
            NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}

private final class FileCell: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let boldFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    private let kind: Column
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let dot = NSImageView()

    init(_ kind: Column) {
        self.kind = kind
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.font = Self.font
        label.alignment = kind == .size || kind == .modified ? .right : .left
        addSubview(label)
        if kind == .name {
            icon.imageScaling = .scaleProportionallyDown
            addSubview(icon)
            dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Marked")
            dot.imageScaling = .scaleProportionallyDown
            addSubview(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    override func layout() {
        super.layout()
        let height: CGFloat = 16
        let y = (bounds.height - height) / 2
        switch kind {
        case .name:
            dot.frame = NSRect(x: 8, y: 7, width: 6, height: 6)
            icon.frame = NSRect(x: 20, y: 3.5, width: 13, height: 13)
            label.frame = NSRect(x: 39, y: y, width: max(bounds.width - 39, 0), height: height)
        case .modified:
            label.frame = NSRect(x: 0, y: y, width: bounds.width - 8, height: height)
        default:
            label.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
        }
    }

    func show(_ entry: FileEntry, isCursor: Bool, isMarked: Bool, style: RowStyle?) {
        let isHidden = entry.isHidden && !entry.isParent
        let ink = isCursor ? Palette.cursorInk : style?.ink
            ?? (isMarked || (kind == .name && !isHidden) ? Palette.ink : Palette.dim)
        label.textColor = ink
        switch kind {
        case .name:
            let font = isMarked || style?.wash != nil || (entry.opensAsFolder && !entry.isParent) ? Self.boldFont : Self.font
            label.font = font
            if let tag = style?.tag {
                let text = NSMutableAttributedString(string: entry.name, attributes: [.font: font, .foregroundColor: ink])
                text.append(NSAttributedString(string: "   \(tag)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ink]))
                label.attributedStringValue = text
            } else {
                label.stringValue = entry.name
            }
            dot.isHidden = !isMarked
            dot.contentTintColor = ink
            icon.image = style?.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: style?.tag) }
                ?? Self.symbol(for: entry)
            icon.contentTintColor = style == nil && !isCursor ? Palette.dim : ink
        case .ext: label.stringValue = entry.ext
        case .size: label.stringValue = entry.size.map(FileSize.format) ?? ""
        case .modified: label.stringValue = entry.modified.map(RowFormat.date) ?? ""
        }
    }

    private static func symbol(for entry: FileEntry) -> NSImage? {
        let name = entry.isParent ? "arrow.up" : entry.isSymlink ? "arrow.up.forward.square"
            : entry.opensAsFolder ? "folder.fill" : "doc"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

}

/// The Modified column's date, wherever files are listed.
@MainActor
enum RowFormat {
    private static let recentFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM HH:mm"
        return formatter
    }()

    private static let olderFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    static func date(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return (sameYear ? recentFormat : olderFormat).string(from: date)
    }
}
