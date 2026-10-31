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
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
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

        func update(_ view: FileTable) {
            guard let table else { return }
            onSelect = { [workspace = view.workspace, index = view.index] row in
                workspace.activate(index)
                workspace.panels[index].setCursor(row)
            }
            table.onKey = { [weak table] event in view.handle(event, page: table?.visibleRows ?? 1) }
            table.onClick = { row, clicks in view.click(row: row, count: clicks) }
            table.onMarkAll = { view.workspace.panels[view.index].markAll() }
            table.quickLookURL = { [panel = view.workspace.panels[view.index]] in
                panel.cursorEntry.flatMap { $0.isParent ? nil : $0.url }
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

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table, table.selectedRow >= 0, table.selectedRow != cursor else { return }
            onSelect(table.selectedRow)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = CursorRowView()
            configure(view, row)
            return view
        }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, let kind = Column(rawValue: column.identifier.rawValue) else { return nil }
            let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? FileCell ?? FileCell(kind)
            cell.identifier = column.identifier
            cell.show(rows[row], isCursor: row == cursor && isActive, isMarked: isMarked(rows[row]))
            return cell
        }
    }

    private func handle(_ event: NSEvent, page: Int) -> Bool {
        let panel = workspace.panels[index]
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
        case 99: QuickLook.toggle()
        case 118: workspace.notBuilt("Edit")
        case 96: workspace.notBuilt("Copy")
        case 97: workspace.notBuilt("Move")
        case 98: workspace.notBuilt("New folder")
        case 100: workspace.notBuilt("Trash")
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
        workspace.activate(index)
        workspace.returnFocus()
        guard row >= 0 else { return }
        let panel = workspace.panels[index]
        panel.setCursor(row)
        if count == 2 { panel.openCursor() }
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
    var onKey: (NSEvent) -> Bool = { _ in false }
    var onClick: (Int, Int) -> Void = { _, _ in }
    var onMarkAll: () -> Void = {}
    var quickLookURL: () -> URL? = { nil }
    private var wantsFocus = false

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
        onClick(row(at: convert(event.locationInWindow, from: nil)), event.clickCount)
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

    override func drawBackground(in dirtyRect: NSRect) {
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

    func show(_ entry: FileEntry, isCursor: Bool, isMarked: Bool) {
        let isHidden = entry.isHidden && !entry.isParent
        let ink = isCursor ? Palette.cursorInk : isMarked || (kind == .name && !isHidden) ? Palette.ink : Palette.dim
        label.textColor = ink
        switch kind {
        case .name:
            label.stringValue = entry.name
            label.font = isMarked || (entry.opensAsFolder && !entry.isParent) ? Self.boldFont : Self.font
            dot.isHidden = !isMarked
            dot.contentTintColor = ink
            icon.image = Self.symbol(for: entry)
            icon.contentTintColor = isCursor ? Palette.cursorInk : Palette.dim
        case .ext: label.stringValue = entry.ext
        case .size: label.stringValue = entry.size.map(FileSize.format) ?? ""
        case .modified: label.stringValue = entry.modified.map(Self.date) ?? ""
        }
    }

    private static func symbol(for entry: FileEntry) -> NSImage? {
        let name = entry.isParent ? "arrow.up" : entry.isSymlink ? "arrow.up.forward.square"
            : entry.opensAsFolder ? "folder.fill" : "doc"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

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

    private static func date(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return (sameYear ? recentFormat : olderFormat).string(from: date)
    }
}
