import AppKit
import CommanderCore
import SwiftUI

@main
struct CommanderApp: App {
    @State private var workspace: Workspace = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let workspace = Workspace(left: home, right: home)
        workspace.openFile = { NSWorkspace.shared.open($0) }
        workspace.start()
        return workspace
    }()

    var body: some Scene {
        Window("Commander", id: "main") {
            ContentView(workspace: workspace)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands { BrowseCommands(workspace: workspace) }
    }
}

/// Keys that work wherever focus is. Keys that only mean something in a list live in `FileTable`.
private struct BrowseCommands: Commands {
    let workspace: Workspace

    private var panel: Panel { workspace.active }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { panel.newTab() }.keyboardShortcut("t")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { panel.closeTab() }
                .keyboardShortcut("w")
                .disabled(panel.tabs.count < 2)
        }
        CommandGroup(after: .toolbar) {
            Button(workspace.showHidden ? "Hide Hidden Files" : "Show Hidden Files") { workspace.toggleHidden() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button("Refresh") { panel.refresh() }.keyboardShortcut("r")
            Divider()
            sortButton("Sort by Name", .name, "1")
            sortButton("Sort by Extension", .ext, "2")
            sortButton("Sort by Size", .size, "3")
            sortButton("Sort by Modified", .modified, "4")
            Divider()
            Button("Next Tab") { panel.nextTab(by: 1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { panel.nextTab(by: -1) }.keyboardShortcut("[", modifiers: [.command, .shift])
        }
        CommandMenu("Go") {
            Button("Back") { panel.goBack() }.keyboardShortcut("[").disabled(!panel.canGoBack)
            Button("Forward") { panel.goForward() }.keyboardShortcut("]").disabled(!panel.canGoForward)
            Button("Enclosing Folder") { panel.goUp() }.keyboardShortcut(.upArrow)
            Button("Open as Folder") { panel.openCursor(asFolder: true) }.keyboardShortcut(.downArrow)
            Button("Go to Path…") { workspace.isGoingToPath = true }.keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            ForEach(Places.favorites()) { place($0) }
            if !workspace.volumes.isEmpty {
                Divider()
                ForEach(workspace.volumes) { place($0) }
            }
            Divider()
            Button("Open Full Disk Access Settings", action: FullDiskAccess.open)
        }
    }

    private func sortButton(_ title: String, _ key: FileSort.Key, _ shortcut: KeyEquivalent) -> some View {
        Button(title) { panel.sort(by: key) }.keyboardShortcut(shortcut, modifiers: [.command, .control])
    }

    private func place(_ place: Place) -> some View {
        Button(place.title) { panel.navigate(to: place.url) }
    }
}
