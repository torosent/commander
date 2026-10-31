import AppKit
import CommanderCore
import SwiftUI

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

private struct TabStrip: View {
    let workspace: Workspace
    let index: Int

    var body: some View {
        let panel = workspace.panels[index]
        HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(panel.tabs.enumerated()), id: \.offset) { offset, tab in
                let isSelected = offset == panel.tabIndex
                Button {
                    workspace.activate(index)
                    panel.selectTab(offset)
                } label: {
                    Text(tab.title)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? Theme.ink : Theme.dim)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(isSelected ? Theme.deck : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 28, alignment: .bottom)
        .background(Theme.caseColor)
    }
}

private struct PathBar: View {
    let workspace: Workspace
    let index: Int
    let isActive: Bool

    var body: some View {
        let panel = workspace.panels[index]
        let crumbs = Places.crumbs(for: panel.location)
        HStack(spacing: 4) {
            nav("chevron.left", "Back", enabled: panel.canGoBack) { panel.goBack() }
            nav("chevron.right", "Forward", enabled: panel.canGoForward) { panel.goForward() }
            PlacesMenu(workspace: workspace, index: index)
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
        HStack(spacing: 0) {
            heading("Name", .name, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            heading("Ext", .ext, alignment: .leading).frame(width: 96, alignment: .leading)
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
            Text("This folder is empty.").foregroundStyle(Theme.dim).allowsHitTesting(false)
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
