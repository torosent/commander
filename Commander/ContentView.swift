import AppKit
import CommanderCore
import SwiftUI

struct ContentView: View {
    let workspace: Workspace

    @AppStorage(Preferences.themeKey) private var theme = AppTheme.system

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()
            HStack(spacing: 0) {
                PanelView(workspace: workspace, index: 0)
                KeyColumn(workspace: workspace)
                PanelView(workspace: workspace, index: 1)
            }
            StatusBar(workspace: workspace)
            CommandLineBar(workspace: workspace)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.caseColor)
        .ignoresSafeArea()
        .background(WindowFrameSaver())
        .onReceive(NSApplication.shared.publisher(for: \.isActive).dropFirst()) { _ in Preferences.save(workspace.session) }
        // The window can close without the app ever going inactive, and this view goes with it.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            Preferences.save(workspace.session)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            Preferences.save(workspace.session)
        }
        .onChange(of: theme, initial: true) { _, theme in NSApp.appearance = theme.appearance }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            workspace.refreshVolumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            workspace.refreshVolumes()
        }
    }
}

private struct TitleStrip: View {
    var body: some View {
        Button {} label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                Text("Run a command")
                Spacer()
                Text("⌘K")
            }
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 12)
            .frame(width: 360, height: 24)
            .background(Theme.deck, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
        .overlay(alignment: .bottom) { Theme.rim.frame(height: 1) }
    }
}

private struct StatusBar: View {
    let workspace: Workspace

    var body: some View {
        Group {
            if workspace.isGoingToPath {
                GoToBar(workspace: workspace)
            } else if let bar = workspace.patternBar {
                PatternEntryBar(workspace: workspace, bar: bar).id(bar.id)
            } else if let message = workspace.message {
                HStack {
                    Text(message)
                    Spacer()
                }
            } else {
                HStack(spacing: 12) {
                    Text("Tab switches panel")
                    Text("Space marks")
                    Text("Type to find")
                    Text("F3 previews")
                    Spacer()
                }
            }
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.deck)
        .overlay(alignment: .top) { Theme.rim.frame(height: 1) }
    }
}

/// Marks update as you type, so the result shows before it's applied.
private struct PatternEntryBar: View {
    let workspace: Workspace
    let bar: PatternBar

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark").foregroundStyle(Theme.ink).accessibilityHidden(true)
            Text(bar.marks ? "Mark" : "Unmark").fontWeight(.semibold).foregroundStyle(Theme.ink)
            TextField("Pattern", text: $text, prompt: Text("*.js, *.ts"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 240)
                .focused($isFocused)
                .onChange(of: text) { _, text in workspace.updatePattern(text) }
                .onSubmit(workspace.applyPattern)
                .onExitCommand(perform: workspace.cancelPattern)
            Text("\(bar.panel.markedCount.formatted()) marked")
            Spacer()
            Button("Cancel", action: workspace.cancelPattern)
            Button("Apply", action: workspace.applyPattern)
        }
        .onAppear {
            text = bar.text
            isFocused = true
        }
    }
}

/// An inline bar in place of a dialog, so both panels stay visible.
private struct GoToBar: View {
    let workspace: Workspace

    @State private var path = ""
    @State private var problem = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder").foregroundStyle(Theme.ink)
            Text("Go to").fontWeight(.semibold).foregroundStyle(Theme.ink)
            TextField("Path", text: $path, prompt: Text("~/projects"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 340)
                .focused($isFocused)
                .onSubmit(go)
                .onExitCommand(perform: close)
            Text(problem)
            Spacer()
            Button("Cancel", action: close)
            Button("Go", action: go)
        }
        .onAppear { isFocused = true }
    }

    private func go() {
        Task {
            if let problem = await workspace.goTo(path: path) {
                self.problem = problem
            } else {
                close()
            }
        }
    }

    private func close() {
        workspace.isGoingToPath = false
        workspace.returnFocus()
    }
}

/// Saves and restores the window's size and position.
private struct WindowFrameSaver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FrameView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class FrameView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.setFrameAutosaveName("Commander")
        }
    }
}

private struct CommandLineBar: View {
    let workspace: Workspace

    @State private var command = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("%").foregroundStyle(Theme.dim)
            TextField("Command line", text: $command, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onExitCommand(perform: workspace.returnFocus)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}
