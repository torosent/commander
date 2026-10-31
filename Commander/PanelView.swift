import AppKit
import CommanderCore
import SwiftUI
import UniformTypeIdentifiers

struct PanelView: View {
    let workspace: Workspace
    let index: Int

    private var panel: Panel { workspace.panels[index] }
    private var isActive: Bool { workspace.activeIndex == index }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(workspace: workspace, index: index)
            PathBar(workspace: workspace, index: index, isActive: isActive)
            ColumnHeader(workspace: workspace, index: index)
            GeometryReader { geometry in
                FileTable(
                    workspace: workspace,
                    index: index,
                    rows: panel.rows,
                    version: panel.rowsVersion,
                    marksVersion: panel.marksVersion,
                    cursor: panel.cursorIndex,
                    isActive: isActive,
                    focusTick: workspace.focusTick,
                    scrollRequest: panel.scrollRequest,
                    edit: panel.edit
                )
                // Whole rows only: the spare space sits below the last row.
                .frame(height: (geometry.size.height / FileTable.rowHeight).rounded(.down) * FileTable.rowHeight)
                .overlay { PanelNotice(panel: panel) }
            }
            Footer(panel: panel)
        }
        .background(Theme.deck)
    }
}

/// The tab being dragged. Its type is private to this app, so text fields and other apps don't take it.
@MainActor
private enum TabDrag {
    /// Declared in Commander-Info.plist, without which the system won't match it to a drop.
    static let type = UTType(exportedAs: "dev.commander.tab")
    static var id: UUID?

    static func start(_ id: UUID) -> NSItemProvider {
        self.id = id
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        return provider
    }
}

/// Which side of a tab the pointer is on decides whether the dragged tab lands before it or after it.
private struct TabDropDelegate: DropDelegate {
    let offset: Int
    let width: CGFloat
    @Binding var target: Int?
    let onDrop: (UUID, Int) -> Void

    private func position(_ info: DropInfo) -> Int {
        info.location.x > width / 2 ? offset + 1 : offset
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        target = position(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        target = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        target = nil
        guard let id = TabDrag.id else { return false }
        onDrop(id, position(info))
        return true
    }
}

/// A width limit that also holds when nothing proposes a width, as inside a scroll view, where a plain
/// `frame(maxWidth:)` lets text run past it rather than truncate.
private struct WidthLimit: Layout {
    let limit: CGFloat

    private func proposal(_ proposed: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposed.width ?? limit, limit), height: proposed.height)
    }

    func sizeThatFits(proposal proposed: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(proposal(proposed)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal proposed: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: proposal(proposed))
    }
}

private struct TabStrip: View {
    private static let widest: CGFloat = 180
    private static let narrowest: CGFloat = 72

    let workspace: Workspace
    let index: Int

    @State private var width: CGFloat = 0
    @State private var tabWidths: [UUID: CGFloat] = [:]
    /// Where a dragged tab would land.
    @State private var dropTarget: Int?

    private var panel: Panel { workspace.panels[index] }

    /// Tabs get narrower as they fill the strip, and past the narrowest it scrolls.
    private var tabWidth: CGFloat {
        min(Self.widest, max(Self.narrowest, width / CGFloat(max(panel.tabs.count, 1))))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ScrollViewReader { reader in
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 1) {
                        ForEach(Array(panel.tabs.enumerated()), id: \.element.id) { offset, tab in
                            tabView(tab, offset)
                        }
                    }
                }
                .scrollIndicators(.never)
                .scrollEdgeEffectHidden()
                .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
                .onChange(of: panel.tab.id) { _, id in reader.scrollTo(id) }
            }
            Button {
                workspace.activate(index)
                panel.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Tab")
        }
        .padding(.horizontal, 8)
        .frame(height: 28, alignment: .bottom)
        .background(Theme.caseColor)
        // The strip's empty space is the far end of it.
        .onDrop(of: [TabDrag.type], delegate: delegate(offset: panel.tabs.count - 1, width: 0))
    }

    private func delegate(offset: Int, width: CGFloat) -> TabDropDelegate {
        TabDropDelegate(offset: offset, width: width, target: $dropTarget) { id, position in
            workspace.moveTab(id, toPanel: index, before: position)
        }
    }

    private func tabView(_ tab: TabState, _ offset: Int) -> some View {
        PanelTab(
            title: tab.title, isSelected: offset == panel.tabIndex, canClose: panel.tabs.count > 1, maxWidth: tabWidth,
            onSelect: {
                workspace.activate(index)
                panel.selectTab(offset)
            },
            onClose: { panel.closeTab(id: tab.id) },
            onMove: { workspace.moveTab(tab.id, toPanel: 1 - index, before: workspace.panels[1 - index].tabIndex + 1) }
        )
        .id(tab.id)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { tabWidths[tab.id] = $0 }
        .onDrag {
            TabDrag.start(tab.id)
        } preview: {
            Text(tab.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Self.widest)
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Theme.deck, in: RoundedRectangle(cornerRadius: 6))
        }
        .overlay(alignment: .leading) {
            if dropTarget == offset { Theme.cursor.frame(width: 2).accessibilityHidden(true) }
        }
        .overlay(alignment: .trailing) {
            if dropTarget == offset + 1, offset == panel.tabs.count - 1 { Theme.cursor.frame(width: 2).accessibilityHidden(true) }
        }
        .onDrop(of: [TabDrag.type], delegate: delegate(offset: offset, width: tabWidths[tab.id] ?? 0))
    }
}

private struct PanelTab: View {
    let title: String
    let isSelected: Bool
    let canClose: Bool
    let maxWidth: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    let onMove: () -> Void

    @State private var isHovered = false

    var body: some View {
        WidthLimit(limit: maxWidth) {
            HStack(spacing: 2) {
                // Not a Button, which would take the mouse-down and stop the tab from being dragged.
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? Theme.ink : Theme.dim)
                    .padding(.leading, 12)
                    .padding(.trailing, canClose ? 2 : 12)
                    .frame(height: 24)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction(.default, onSelect)
                    .accessibilityAction(named: "Move to Other Panel", onMove)
                if canClose {
                    // Always in the layout, so a tab doesn't change width as the pointer crosses it.
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.dim)
                            .frame(width: 14, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isSelected || isHovered ? 1 : 0)
                    .padding(.trailing, 4)
                    .accessibilityLabel("Close \(title)")
                }
            }
        }
        .background(isSelected ? Theme.deck : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
        .onHover { isHovered = $0 }
    }
}

private struct PathBar: View {
    let workspace: Workspace
    let index: Int
    let isActive: Bool

    var body: some View {
        let panel = workspace.panels[index]
        let crumbs = panel.isResults ? [] : Places.crumbs(for: panel.location)
        HStack(spacing: 4) {
            nav("chevron.left", "Back", enabled: panel.canGoBack) { panel.goBack() }
            nav("chevron.right", "Forward", enabled: panel.canGoForward) { panel.goForward() }
            PlacesMenu(workspace: workspace, index: index)
            if panel.isResults {
                Text("Find results").fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1)
            }
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.element.id) { offset, crumb in
                    let isLast = offset == crumbs.count - 1
                    Button(crumb.title) { go(to: crumb.url) }
                        .buttonStyle(.plain)
                        .lineLimit(1)
                        .fontWeight(isLast ? .semibold : .regular)
                        .foregroundStyle(isLast ? Theme.ink : Theme.dim)
                        .disabled(isLast)
                    // The root crumb is already a slash.
                    if !isLast, crumb.title != "/" {
                        Text("/").foregroundStyle(Theme.dim).accessibilityHidden(true)
                    }
                }
            }
            Spacer(minLength: 8)
            if let free = panel.freeSpace {
                Text("\(FileSize.format(free)) free").foregroundStyle(Theme.dim).lineLimit(1).fixedSize()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .overlay(alignment: .top) {
            if isActive { Theme.cursor.frame(height: 2) }
        }
    }

    private func nav(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            workspace.activate(index)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.ink : Theme.dim.opacity(0.45))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func go(to url: URL) {
        workspace.activate(index)
        workspace.panels[index].navigate(to: url)
    }
}

private struct PlacesMenu: View {
    let workspace: Workspace
    let index: Int

    var body: some View {
        Menu {
            Section("Favorites") {
                ForEach(Places.favorites()) { button($0) }
            }
            Section("Volumes") {
                ForEach(workspace.volumes) { button($0) }
            }
        } label: {
            Image(systemName: "externaldrive").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.dim)
        .accessibilityLabel("Places")
    }

    private func button(_ place: Place) -> some View {
        Button(place.title) {
            workspace.activate(index)
            workspace.panels[index].navigate(to: place.url)
        }
    }
}

private struct ColumnHeader: View {
    let workspace: Workspace
    let index: Int

    var body: some View {
        let isResults = workspace.panels[index].isResults
        HStack(spacing: 0) {
            heading("Name", .name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            if isResults {
                heading("Folder", .folder, alignment: .leading).frame(width: FileTable.folderWidth, alignment: .leading)
            } else {
                heading("Ext", .ext, alignment: .leading).frame(width: 96, alignment: .leading)
            }
            heading("Size", .size, alignment: .trailing).frame(width: 84, alignment: .trailing)
            heading("Modified", .modified, alignment: .trailing).frame(width: 106, alignment: .trailing)
        }
        .font(Theme.label)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func heading(_ title: String, _ key: FileSort.Key, alignment: Alignment) -> some View {
        let panel = workspace.panels[index]
        let sort = panel.tab.sort
        let isSorted = sort.key == key
        return Button {
            workspace.activate(index)
            panel.sort(by: key)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if isSorted {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .accessibilityHidden(true)
                }
            }
            .fontWeight(isSorted ? .semibold : .regular)
            .foregroundStyle(isSorted ? Theme.ink : Theme.dim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSorted ? (sort.ascending ? "Ascending" : "Descending") : "")
    }
}

private struct Footer: View {
    let panel: Panel

    var body: some View {
        HStack {
            if panel.query.isEmpty {
                Text(summary)
                if let status = panel.findStatus { Text(status) }
                Spacer()
                Text(FileSize.format(panel.visibleSize))
            } else {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).accessibilityHidden(true)
                Text(panel.query).foregroundStyle(Theme.ink).fontWeight(.semibold)
                Spacer()
                if panel.queryFailed { Text("No match") }
            }
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Theme.caseColor)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private var summary: String {
        let count = panel.visibleCount
        let items = "\(count.formatted()) item\(count == 1 ? "" : "s")"
        return panel.hiddenCount > 0 ? "\(items) · \(panel.hiddenCount.formatted()) hidden" : items
    }
}

/// Explains an empty panel. A folder that can't be read says why and how to fix it.
private struct PanelNotice: View {
    let panel: Panel

    var body: some View {
        if let failure = panel.tab.failure {
            VStack(spacing: 8) {
                Text(title(failure)).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Text(detail(failure)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
                if failure == .permissionDenied {
                    Button("Open Full Disk Access Settings", action: FullDiskAccess.open)
                }
            }
            .padding(16)
            .frame(maxWidth: 360)
        } else if !panel.isLoading, panel.tab.entries.isEmpty {
            if !panel.isResults {
                Text("This folder is empty.").foregroundStyle(Theme.dim).allowsHitTesting(false)
            } else if panel.tab.title != "Find", panel.findStatus == nil {
                Text("No files match.").foregroundStyle(Theme.dim).allowsHitTesting(false)
            }
        }
    }

    private func title(_ failure: ListingError) -> String {
        switch failure {
        case .permissionDenied: "Commander can't read this folder."
        case .notFound: "This folder no longer exists."
        case .notAFolder: "This isn't a folder."
        case .other: "This folder couldn't be read."
        }
    }

    private func detail(_ failure: ListingError) -> String {
        switch failure {
        case .permissionDenied: "Give Commander Full Disk Access in System Settings, then come back. Press ⌘[ to go back."
        case .notFound, .notAFolder: "Press ⌘[ to go back."
        case .other(let message): message
        }
    }
}

enum FullDiskAccess {
    static func open() {
        let address = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }
}
