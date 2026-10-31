import AppKit
import CommanderCore
import SwiftUI

struct ContentView: View {
    let workspace: Workspace

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()
            HStack(spacing: 0) {
                PanelView(workspace: workspace, index: 0)
                KeyColumn()
                PanelView(workspace: workspace, index: 1)
            }
            StatusBar(workspace: workspace)
            CommandLineBar(workspace: workspace)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.caseColor)
        .ignoresSafeArea()
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
            } else if let message = workspace.message {
                HStack {
                    Text(message)
                    Spacer()
                }
            } else {
                HStack(spacing: 12) {
                    Text("Tab switches panel")
                    Text("⌘⇧G goes to a path")
                    Text("⌘⇧. shows hidden files")
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
