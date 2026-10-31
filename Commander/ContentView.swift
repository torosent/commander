import AppKit
import CommanderCore
import SwiftUI

struct ContentView: View {
    let workspace: Workspace

    @AppStorage(Preferences.themeKey) private var theme = AppTheme.system

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(workspace: workspace)
            if let session = workspace.renameSession {
                MultiRenameView(workspace: workspace, session: session)
            } else if let session = workspace.compareSession {
                CompareView(workspace: workspace, session: session)
            } else {
                HStack(spacing: 0) {
                    side(0)
                    KeyColumn(workspace: workspace)
                    side(1)
                }
            }
            StatusBar(workspace: workspace)
            CommandLineBar(workspace: workspace)
        }
        .overlay {
            if workspace.isPaletteOpen { CommandPalette(workspace: workspace) }
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

extension ContentView {
    @ViewBuilder
    fileprivate func side(_ index: Int) -> some View {
        if let viewer = workspace.viewer, index == workspace.viewerIndex {
            ViewerPanel(workspace: workspace, viewer: viewer)
        } else {
            PanelView(workspace: workspace, index: index)
        }
    }
}

private struct TitleStrip: View {
    let workspace: Workspace

    var body: some View {
        Button(action: workspace.openPalette) {
            label
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

    private var label: some View {
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
}

private struct StatusBar: View {
    let workspace: Workspace

    var body: some View {
        Group {
            if let session = workspace.renameSession {
                RenameBar(workspace: workspace, session: session)
            } else if let session = workspace.compareSession, workspace.jobs.current == nil {
                CompareBar(workspace: workspace, session: session)
            } else if let pending = workspace.pending, let draft = pending.archive {
                CompressBar(workspace: workspace, pending: pending, draft: draft)
            } else if let pending = workspace.pending {
                OperationBar(workspace: workspace, pending: pending)
            } else if workspace.isGoingToPath {
                GoToBar(workspace: workspace)
            } else if let bar = workspace.patternBar {
                PatternEntryBar(workspace: workspace, bar: bar).id(bar.id)
            } else if let session = workspace.find, session.isBarOpen {
                FindBar(workspace: workspace, session: session)
            } else if let job = workspace.jobs.current {
                JobBar(workspace: workspace, job: job)
            } else if let command = workspace.runningCommand {
                HStack(spacing: 12) {
                    Text("Running").fontWeight(.semibold).foregroundStyle(Theme.ink)
                    Text(command).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Button("Stop", action: workspace.stopCommand)
                }
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
        case .rename: "Renaming"
        case .extract: "Extracting"
        case .compress: "Compressing"
        case .sync: "Syncing"
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
    private var isReplacing: Bool { pending.choice == .replace && !preview.conflicts.isEmpty }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1)
            if isReplacing {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.removeText).accessibilityHidden(true)
            }
            Text(detail).foregroundStyle(isReplacing ? Theme.removeText : Theme.dim).lineLimit(1)
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
        case .rename: "Rename"
        case .extract: "Extract"
        case .compress: "Compress"
        case .sync: "Sync"
        }
    }

    private var tint: Color {
        switch preview.kind {
        case .copy, .extract, .compress, .sync: Theme.goFill
        case .move: Theme.moveFill
        case .trash, .delete: Theme.removeFill
        case .rename: Theme.cursor
        }
    }

    private var title: String {
        switch preview.kind {
        case .copy, .move, .rename, .extract, .compress, .sync: "\(verb) to \(preview.folder?.lastPathComponent ?? "")"
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
        case .copy, .move, .rename, .extract, .compress, .sync:
            if preview.items.count > conflicts { parts.append("\(preview.items.count - conflicts) new") }
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

/// Names a new archive. The ghost row in the destination follows the name as it's typed.
private struct CompressBar: View {
    let workspace: Workspace
    let pending: PendingOperation
    let draft: ArchiveDraft

    @FocusState private var isFocused: Bool

    private var count: Int { pending.preview.items.count }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "archivebox").foregroundStyle(Color(nsColor: Palette.goText)).accessibilityHidden(true)
            Text("Compress \(count) item\(count == 1 ? "" : "s") to \(pending.preview.folder?.lastPathComponent ?? "")")
                .fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
            TextField("Archive name", text: Binding(
                get: { draft.name },
                set: { workspace.updateArchive(ArchiveDraft(name: $0, format: draft.format)) }
            ))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 180)
            .focused($isFocused)
            .onSubmit(workspace.runOperation)
            .onExitCommand(perform: workspace.cancelOperation)
            // Letters go into the name, so Tab is what's left for the keyboard.
            .onKeyPress(.tab) {
                let next: ArchiveFormat = draft.format == .zip ? .tarGz : .zip
                workspace.updateArchive(ArchiveDraft(name: draft.name, format: next))
                return .handled
            }
            Picker("Format", selection: Binding(
                get: { draft.format },
                set: { workspace.updateArchive(ArchiveDraft(name: draft.name, format: $0)) }
            )) {
                ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Text("Tab").foregroundStyle(Theme.dim).accessibilityHidden(true)
            Text(workspace.archiveProblem ?? "").foregroundStyle(Theme.dim).lineLimit(1)
            Spacer()
            Button("Cancel", action: workspace.cancelOperation)
            Button("Compress  ↩", action: workspace.runOperation)
                .buttonStyle(.borderedProminent)
                .tint(Theme.goFill)
                .disabled(workspace.archiveProblem != nil)
        }
        // The table redraws in the same pass, and SwiftUI would undo a focus change made during it.
        .onAppear { DispatchQueue.main.async { isFocused = true } }
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

/// Fills a results tab as you type, so the search can be narrowed while it runs.
private struct FindBar: View {
    private enum Field {
        case name, contains
    }

    let workspace: Workspace
    @Bindable var session: FindSession

    @FocusState private var focus: Field?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink).accessibilityHidden(true)
            Text("Find").fontWeight(.semibold).foregroundStyle(Theme.ink)
            Text("Name")
            field("File name", $session.query.name, prompt: "*.md", .name)
            Text("Contains")
            field("File contents", $session.query.contains, prompt: "", .contains)
            Picker("Search in", selection: $session.scope) {
                Text("Folder ⌘1").tag(FindScope.folder)
                Text("Volume ⌘2").tag(FindScope.volume)
                Text("All ⌘3").tag(FindScope.allVolumes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .background { scopeKeys }
            Spacer()
            Button("Cancel  esc", action: workspace.cancelFind)
            Button("Keep Results  ↩", action: workspace.keepFind).disabled(session.query.isEmpty)
        }
        // The table redraws in the same pass, and SwiftUI would undo a focus change made during it.
        .onAppear { DispatchQueue.main.async { focus = .name } }
    }

    private func field(_ title: String, _ text: Binding<String>, prompt: String, _ name: Field) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
            .frame(width: 160)
            .focused($focus, equals: name)
            .onSubmit(workspace.keepFind)
            .onExitCommand(perform: workspace.cancelFind)
    }

    /// The keys for the scope, which a segmented control has no way to take.
    private var scopeKeys: some View {
        ForEach(Array(FindScope.allCases.enumerated()), id: \.element) { offset, scope in
            Button("") { session.scope = scope }
                .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")))
                .opacity(0)
                .accessibilityHidden(true)
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
                .onChange(of: workspace.commandLineTick) { isFocused = true }
                .onExitCommand(perform: workspace.returnFocus)
                .onSubmit {
                    workspace.runCommandLine(command)
                    command = ""
                    workspace.returnFocus()
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}
