import AppKit
import CommanderCore
import SwiftUI

/// Quitting mid-job has to be a choice, and a stopped job needs a moment to clear its temp files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: Workspace?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace, workspace.jobs.current != nil || workspace.runningCommand != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Something is still running"
        alert.informativeText = "Quitting stops it and cancels any jobs waiting. Items already finished stay where they are."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop and Quit")
        // The app stays stuck on this question, so it must stay in view after switching away.
        alert.window.hidesOnDeactivate = false
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        workspace.jobs.stopAll()
        workspace.stopCommand()
        Task {
            await workspace.jobs.finished()
            await workspace.commandDone()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct CommanderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var workspace: Workspace = {
        let workspace = Workspace(
            session: Preferences.savedSession,
            fallback: FileManager.default.homeDirectoryForCurrentUser,
            showHidden: UserDefaults.standard.bool(forKey: Preferences.showHiddenKey)
        )
        workspace.openFile = { NSWorkspace.shared.open($0) }
        workspace.desktop = .app
        workspace.start()
        return workspace
    }()

    var body: some Scene {
        Window("Commander", id: "main") {
            ContentView(workspace: workspace)
                .frame(minWidth: 1000, minHeight: 600)
                .onAppear { appDelegate.workspace = workspace }
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
            Button("New Folder") { panel.beginNewFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(workspace.isTyping)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { panel.closeTab() }
                .keyboardShortcut("w")
                .disabled(panel.tabs.count < 2)
            Divider()
            operationButton("Copy to Other Panel", .copy).keyboardShortcut("c", modifiers: [.command, .shift])
            operationButton("Move to Other Panel", .move).keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Edit") { workspace.edit() }
                .keyboardShortcut("e")
                .disabled(workspace.isTyping)
            Button("Rename") { panel.beginRename() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(workspace.isTyping)
            Button("Multi-Rename…", action: workspace.beginRename)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(workspace.isTyping)
            Button("Compress…", action: workspace.beginCompress)
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(workspace.isTyping)
            Button("Extract", action: workspace.beginExtract)
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(workspace.isTyping)
            Button("Compare and Sync…", action: workspace.beginCompare)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(workspace.isTyping)
            Button("Show Actions") { NSApp.sendAction(#selector(KeyTable.showActions(_:)), to: nil, from: nil) }
                .keyboardShortcut("m", modifiers: [.command, .option])
            Button("Copy Path") { workspace.copyPath() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(workspace.isTyping)
            Button("Open Terminal Here") { workspace.openTerminal() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            // ⌘⌫ means delete to line start in a text field, so these step aside while typing.
            operationButton("Move to Trash", .trash).keyboardShortcut(.delete)
            operationButton("Delete Permanently…", .delete).keyboardShortcut(.delete, modifiers: [.command, .option])
            Divider()
            Button("Stop Job", action: workspace.jobs.stopCurrent).disabled(workspace.jobs.current == nil)
            Button("Stop Command", action: workspace.stopCommand).disabled(workspace.runningCommand == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Move Here") { workspace.paste(Pasteboard.fileURLs(), move: true) }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(workspace.isTyping)
        }
        CommandGroup(after: .toolbar) {
            Button("Command Palette") { workspace.isPaletteOpen ? workspace.closePalette() : workspace.openPalette() }
                .keyboardShortcut("k")
            Button("Go to Command Line", action: workspace.focusCommandLine).keyboardShortcut("l")
            Divider()
            Button(workspace.viewer == nil ? "View Beside" : "Close Viewer", action: workspace.toggleViewer)
                .keyboardShortcut("y")
                .disabled(workspace.isTyping)
            Button("Show as Text or Hex") { workspace.viewer?.toggleHex() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(workspace.viewer == nil)
            Button("Quick Look", action: QuickLook.toggle).keyboardShortcut("y", modifiers: [.command, .shift])
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

    private func operationButton(_ title: String, _ kind: OperationKind) -> some View {
        Button(title) { workspace.begin(kind) }.disabled(workspace.isTyping)
    }

    private func sortButton(_ title: String, _ key: FileSort.Key, _ shortcut: KeyEquivalent) -> some View {
        Button(title) { panel.sort(by: key) }.keyboardShortcut(shortcut, modifiers: [.command, .control])
    }

    private func place(_ place: Place) -> some View {
        Button(place.title) { panel.navigate(to: place.url) }
    }
}
