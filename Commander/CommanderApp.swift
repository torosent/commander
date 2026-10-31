import AppKit
import CommanderCore
import SwiftUI

@main
struct CommanderApp: App {
    @State private var workspace: Workspace = {
        let workspace = Workspace(
            session: Preferences.savedSession,
            fallback: FileManager.default.homeDirectoryForCurrentUser,
            showHidden: UserDefaults.standard.bool(forKey: Preferences.showHiddenKey)
        )
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

        Settings { SettingsView() }
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
            Button("Quick Look", action: QuickLook.toggle).keyboardShortcut("y")
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
        CommandMenu("Mark") {
            Button("Mark or Unmark") { panel.toggleMark() }
            Button("Mark All") { panel.markAll() }
            Button("Invert Marks") { panel.invertMarks() }
            Button("Clear Marks") { panel.clearMarks() }
            Divider()
            Button("Mark by Pattern…") { workspace.beginPattern(marks: true) }
            Button("Unmark by Pattern…") { workspace.beginPattern(marks: false) }
        }
        CommandMenu("Go") {
            Button("Back") { panel.goBack() }.keyboardShortcut("[").disabled(!panel.canGoBack)
            Button("Forward") { panel.goForward() }.keyboardShortcut("]").disabled(!panel.canGoForward)
            Button("Enclosing Folder") { panel.goUp() }.keyboardShortcut(.upArrow)
            Button("Open as Folder") { panel.openCursor(asFolder: true) }.keyboardShortcut(.downArrow)
            Button("Go to Path…") { workspace.beginGoTo() }.keyboardShortcut("g", modifiers: [.command, .shift])
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
