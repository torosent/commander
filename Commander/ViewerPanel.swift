import AppKit
import CommanderCore
import Quartz
import SwiftUI

/// The viewer, in place of the panel opposite the active one.
struct ViewerPanel: View {
    let workspace: Workspace
    let viewer: Viewer

    var body: some View {
        VStack(spacing: 0) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Theme.deck)
        .font(Theme.body)
        // A short wait, so holding an arrow key doesn't open every file on the way.
        .task(id: workspace.active.cursorEntry) {
            try? await Task.sleep(for: .milliseconds(60))
            if !Task.isCancelled { viewer.follow(workspace.active.cursorEntry) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").foregroundStyle(Theme.dim).accessibilityHidden(true)
            Text(viewer.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
            Spacer()
            if viewer.file != nil, viewer.notice == nil {
                Button(viewer.mode == .hex ? "Text" : "Hex", action: viewer.toggleHex)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.dim)
            }
            Button(action: workspace.closeViewer) {
                Image(systemName: "xmark").foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close viewer")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Theme.caseColor)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    @ViewBuilder
    private var content: some View {
        if let notice = viewer.notice {
            Text(notice).foregroundStyle(Theme.dim)
        } else if viewer.mode == .quickLook, let url = viewer.url {
            QuickLookView(url: url, modified: viewer.modified)
        } else if let file = viewer.file {
            PagedView(file: file, url: viewer.url, mode: viewer.mode, focusTick: workspace.viewerFocusTick, workspace: workspace, viewer: viewer)
        }
    }

    private var footer: some View {
        HStack {
            Text(viewer.file.map { FileSize.format($0.size) } ?? "")
            Spacer()
            Text(viewer.modified?.formatted(date: .abbreviated, time: .shortened) ?? "")
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}

private struct QuickLookView: NSViewRepresentable {
    let url: URL
    let modified: Date?

    final class Coordinator {
        var modified: Date?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> QLPreviewView {
        QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
    }

    /// One view stays for every file, because a new one shows black until its first page is ready.
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.modified != modified {
            view.refreshPreviewItem()
        }
        context.coordinator.modified = modified
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

private struct PagedView: NSViewRepresentable {
    let file: PagedFile
    let url: URL?
    let mode: Viewer.Mode
    let focusTick: Int
    let workspace: Workspace
    let viewer: Viewer

    func makeNSView(context: Context) -> PagedTextView {
        let view = PagedTextView()
        view.focusTick = focusTick
        return view
    }

    func updateNSView(_ view: PagedTextView, context: Context) {
        view.onLeave = workspace.returnFocus
        view.onClose = workspace.closeViewer
        view.onToggle = viewer.toggleHex
        view.show(file, url: url, hex: mode == .hex)
        if view.focusTick != focusTick {
            view.focusTick = focusTick
            view.window?.makeFirstResponder(view)
        }
    }
}

/// Draws only the rows on screen, from a position in the file, so its size makes no difference.
/// shortcut: text can't be selected, so nothing can be copied out of the viewer. Add selection if that's missed.
final class PagedTextView: NSView {
    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let rowHeight: CGFloat = 19
    private static let inset: CGFloat = 8
    private static let charWidth = ("M" as NSString).size(withAttributes: [.font: font]).width

    var focusTick = 0
    var onLeave: () -> Void = {}
    var onClose: () -> Void = {}
    var onToggle: () -> Void = {}

    /// What the end of the file was worked out for. Finding it reads back from the end, so it's kept.
    private struct End: Equatable {
        let size: Int64
        let columns: Int
        let rows: Int
        let isHex: Bool
    }

    private var file: PagedFile?
    private var url: URL?
    private var end: (key: End, start: Int64)?
    private var isHex = false
    private var offset: Int64 = 0
    private var rows: [PagedFile.Row] = []
    private var wheel: CGFloat = 0
    private let scroller = NSScroller()

    override init(frame: NSRect) {
        super.init(frame: frame)
        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrolled)
        addSubview(scroller)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("File contents")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func accessibilityValue() -> Any? {
        rows.map(\.text).joined(separator: "\n")
    }

    /// A reload of the same file stays where it was.
    func show(_ file: PagedFile, url: URL?, hex: Bool) {
        guard file !== self.file || hex != isHex else { return }
        if url != self.url {
            offset = 0
        } else if hex == isHex {
            // The same view of a newer copy.
        } else if hex {
            offset -= offset % Int64(hexWidth)
        } else {
            offset = file.rowStart(near: offset)
        }
        self.file = file
        self.url = url
        isHex = hex
        end = nil
        reload()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        scroller.frame = NSRect(x: newSize.width - width, y: 0, width: width, height: newSize.height)
        reload()
    }

    private var columns: Int {
        max(Int((bounds.width - scroller.frame.width - Self.inset * 2) / Self.charWidth), 20)
    }

    private var visibleRows: Int {
        max(Int((bounds.height - Self.inset * 2) / Self.rowHeight), 1)
    }

    private var hexWidth: Int { PagedFile.hexWidth(columns: columns) }

    /// Where the view rests when scrolled to the end.
    private var lastStart: Int64 {
        guard let file else { return 0 }
        let key = End(size: file.size, columns: columns, rows: visibleRows, isHex: isHex)
        if let end, end.key == key { return end.start }
        let start: Int64
        if isHex {
            let total = (key.size + Int64(hexWidth) - 1) / Int64(hexWidth)
            start = max(total - Int64(visibleRows), 0) * Int64(hexWidth)
        } else {
            start = file.start(rowsBefore: key.size, count: visibleRows, columns: columns)
        }
        end = (key, start)
        return start
    }

    private func reload() {
        guard let file else { return }
        // A file can shrink under the view.
        offset = min(offset, lastStart)
        rows = isHex
            ? file.hexRows(from: offset, count: visibleRows, width: hexWidth)
            : file.rows(from: offset, count: visibleRows, columns: columns)
        let last = lastStart
        let shown = (rows.last?.next ?? offset) - offset
        scroller.isEnabled = last > 0
        scroller.knobProportion = CGFloat(max(Double(shown) / Double(max(file.size, 1)), 0.02))
        scroller.doubleValue = last > 0 ? Double(offset) / Double(last) : 0
        needsDisplay = true
    }

    private func move(by count: Int) {
        guard let file, count != 0 else { return }
        if isHex {
            offset += Int64(count * hexWidth)
        } else if count > 0 {
            offset = file.rows(from: offset, count: count + 1, columns: columns).last?.offset ?? offset
        } else {
            offset = file.start(rowsBefore: offset, count: -count, columns: columns)
        }
        offset = min(max(offset, 0), lastStart)
        reload()
    }

    private func jump(to fraction: Double) {
        guard let file else { return }
        let target = Int64(fraction * Double(lastStart))
        // The very end is exact. Snapping to a line start would fall short of a long last line.
        offset = fraction >= 1 ? lastStart : isHex ? target - target % Int64(hexWidth) : file.rowStart(near: target)
        reload()
    }

    @objc private func scrolled() {
        switch scroller.hitPart {
        case .decrementPage: move(by: -visibleRows)
        case .incrementPage: move(by: visibleRows)
        case .knob, .knobSlot: jump(to: scroller.doubleValue)
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: Palette.ink]
        for (index, row) in rows.enumerated() {
            let point = NSPoint(x: Self.inset, y: Self.inset + CGFloat(index) * Self.rowHeight)
            (row.text as NSString).draw(at: point, withAttributes: attributes)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        wheel -= event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / Self.rowHeight : event.scrollingDeltaY
        let whole = Int(wheel)
        wheel -= CGFloat(whole)
        move(by: whole)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(by: 1)
        case 126: move(by: -1)
        case 121, 49: move(by: visibleRows)
        case 116: move(by: -visibleRows)
        case 115: jump(to: 0)
        case 119: jump(to: 1)
        case 48: onLeave()
        case 53, 99: onClose()
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "h", event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                onToggle()
            } else if !event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                super.keyDown(with: event)
            }
        }
    }
}
