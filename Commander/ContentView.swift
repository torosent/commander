import AppKit
import CommanderCore
import SwiftUI

struct ContentView: View {
    let workspace: Workspace

    @AppStorage(Preferences.themeKey) private var theme = AppTheme.system

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(workspace: workspace)
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
    let workspace: Workspace

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
        .overlay(alignment: .trailing) {
            // Something else has the status bar, so the running job shows here.
            if let job = workspace.jobs.current, workspace.pending != nil || workspace.isTyping {
                Text("\(JobText.verb(job.kind)) \(Int(job.fraction * 100))%")
                    .foregroundStyle(Theme.dim)
                    .padding(.trailing, 14)
            }
        }
        .overlay(alignment: .bottom) { Theme.rim.frame(height: 1) }
    }
}

private struct StatusBar: View {
    let workspace: Workspace

    var body: some View {
        Group {
            if let pending = workspace.pending {
                OperationBar(workspace: workspace, pending: pending)
            } else if workspace.isGoingToPath {
                GoToBar(workspace: workspace)
            } else if let bar = workspace.patternBar {
                PatternEntryBar(workspace: workspace, bar: bar).id(bar.id)
            } else if let job = workspace.jobs.current {
                JobBar(workspace: workspace, job: job)
            } else if let report = workspace.report {
                HStack(spacing: 12) {
                    Text(report.summary).foregroundStyle(Theme.ink).lineLimit(1)
                    Spacer()
                    Button("Dismiss", action: workspace.dismissReport)
                }
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

enum JobText {
    static func verb(_ kind: OperationKind) -> String {
        switch kind {
        case .copy: "Copying"
        case .move: "Moving"
        case .trash: "Moving to Trash"
        case .delete: "Deleting"
        }
    }
}

private struct JobBar: View {
    let workspace: Workspace
    let job: Job

    var body: some View {
        HStack(spacing: 12) {
            Text("\(JobText.verb(job.kind)) \(min(job.itemsDone + 1, job.itemCount)) of \(job.itemCount)")
                .fontWeight(.semibold).foregroundStyle(Theme.ink)
            Text(job.currentName).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
            ProgressView(value: job.fraction).progressViewStyle(.linear)
            Text("\(Int(job.fraction * 100))%")
            if !workspace.jobs.waiting.isEmpty {
                Text("\(workspace.jobs.waiting.count) waiting")
            }
            Button("Stop", action: workspace.jobs.stopCurrent)
        }
    }
}

/// The confirmation for a previewed operation. It's inline, so the preview rows stay in view.
private struct OperationBar: View {
    let workspace: Workspace
    let pending: PendingOperation

    private var preview: OperationPreview { pending.preview }
    private var count: Int { preview.runCount(pending.choice) }
    private var items: String { "\(count) item\(count == 1 ? "" : "s")" }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1)
            Text(detail).foregroundStyle(pending.choice == .replace && !preview.conflicts.isEmpty ? Theme.removeText : Theme.dim).lineLimit(1)
            Spacer()
            if !preview.conflicts.isEmpty {
                Picker("If a file exists", selection: Binding(get: { pending.choice }, set: workspace.choose)) {
                    Text("Replace R").tag(ConflictChoice.replace)
                    Text("Skip S").tag(ConflictChoice.skip)
                    Text("Keep Both K").tag(ConflictChoice.keepBoth)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Button("Cancel", action: workspace.cancelOperation)
            if preview.kind == .delete {
                Button("Delete Forever  D", role: .destructive, action: workspace.runOperation).tint(.red)
            } else {
                Button("\(verb) \(items)  ↩", action: workspace.runOperation)
                    .buttonStyle(.borderedProminent)
                    .tint(tint)
                    .disabled(count == 0)
            }
        }
    }

    private var verb: String {
        switch preview.kind {
        case .copy: "Copy"
        case .move: "Move"
        case .trash: "Trash"
        case .delete: "Delete"
        }
    }

    private var tint: Color {
        switch preview.kind {
        case .copy: Theme.rgb(0x3FA34D)
        case .move: Theme.rgb(0xB88A00)
        case .trash, .delete: Theme.rgb(0xD8412F)
        }
    }

    private var title: String {
        switch preview.kind {
        case .copy, .move: "\(verb) to \(preview.folder?.lastPathComponent ?? "")"
        case .trash: "Move \(items) to Trash"
        case .delete: "Permanently delete \(items)"
        }
    }

    private var detail: String {
        let conflicts = preview.conflicts.count
        var parts: [String] = []
        switch preview.kind {
        case .trash: parts.append("You can restore these from the Trash")
        case .delete: parts.append("This can't be undone")
        case .copy, .move:
            parts.append("\(preview.items.count - conflicts) new")
            if conflicts > 0 {
                let what = switch pending.choice {
                case .replace: "replaced"
                case .skip: "skipped"
                case .keepBoth: "kept beside the original"
                }
                parts.append("\(conflicts) \(what)")
            }
            let newer = preview.conflicts.count { $0.existing?.isNewer == true }
            if newer > 0 { parts.append("\(newer) newer there") }
            if preview.alreadyThere > 0 { parts.append("\(preview.alreadyThere) already there") }
        }
        return parts.joined(separator: " · ")
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
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("%").foregroundStyle(Theme.dim)
            TextField("Command line", text: $command, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in workspace.isCommandLineFocused = focused }
                .onExitCommand(perform: workspace.returnFocus)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}
