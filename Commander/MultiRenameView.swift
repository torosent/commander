import CommanderCore
import SwiftUI

/// Before, lanes, after, in the panels' own column grid. One scroll view holds both sides, so they can't drift.
struct MultiRenameView: View {
    let workspace: Workspace
    @Bindable var session: RenameSession

    @FocusState private var isNameFocused: Bool
    @State private var topRow: URL?
    @State private var pageRows = 30

    var body: some View {
        VStack(spacing: 0) {
            options
            HStack(spacing: 0) {
                head("Before", session.folder.lastPathComponent)
                Theme.caseColor.frame(width: 84)
                head("After", "\(session.changedCount) change")
            }
            .frame(height: 50)
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    Theme.deck
                    Theme.caseColor.frame(width: 84)
                    Theme.deck
                }
                // Whole rows only: the spare space sits below the last row.
                GeometryReader { geometry in
                    list.frame(height: (geometry.size.height / 20).rounded(.down) * 20)
                }
            }
        }
        .font(Theme.body)
        .onSubmit(workspace.runRename)
        .onExitCommand(perform: workspace.cancelRename)
        .onKeyPress(keys: [.pageUp, .pageDown]) { press in
            page(press.key == .pageDown ? 1 : -1)
            return .handled
        }
        .onAppear { isNameFocused = true }
    }

    /// Focus stays in the fields, so these keys scroll the list from there.
    private func page(_ direction: Int) {
        let rows = session.rows
        let top = rows.firstIndex { $0.id == topRow } ?? 0
        topRow = rows[min(max(top + direction * pageRows, 0), max(rows.count - pageRows, 0))].id
    }

    private var options: some View {
        HStack(spacing: 10) {
            field("Name", $session.options.name, width: 150).focused($isNameFocused)
            field("Ext", $session.options.ext, width: 64)
            field("Find", $session.options.find, width: 100)
            field("Replace", $session.options.replacement, width: 100)
            Toggle("Regex", isOn: $session.options.usesRegex).toggleStyle(.checkbox)
            Picker("Case", selection: $session.options.caseChange) {
                Text("Keep").tag(CaseChange.keep)
                Text("lower").tag(CaseChange.lower)
                Text("UPPER").tag(CaseChange.upper)
                Text("Title").tag(CaseChange.title)
            }
            .pickerStyle(.menu)
            .fixedSize()
            number("Counter", \.counterStart, in: -999_999...999_999)
            number("Step", \.counterStep, in: -999...999)
            number("Digits", \.counterDigits, in: 1...9)
            Spacer(minLength: 0)
            Text("[N] name · [N1-5] part · [E] ext · [C] counter · [YMD] date")
                .lineLimit(1)
                .layoutPriority(-1)
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.caseColor)
        .overlay(alignment: .bottom) { Theme.rim.frame(height: 1) }
    }

    private func field(_ title: String, _ text: Binding<String>, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title).fixedSize().accessibilityHidden(true)
            TextField(title, text: text, prompt: Text(""))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .font(.system(size: 12, design: .monospaced))
                .frame(width: width)
                .accessibilityLabel(title)
        }
    }

    /// Edited as text, so Return runs the rename rather than committing a number field.
    private func number(_ title: String, _ value: WritableKeyPath<RenameOptions, Int>, in range: ClosedRange<Int>) -> some View {
        field(title, Binding(
            get: { String(session.options[keyPath: value]) },
            set: { text in
                if let number = Int(text) { session.options[keyPath: value] = min(max(number, range.lowerBound), range.upperBound) }
            }
        ), width: 46)
    }

    private func head(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Text(detail).foregroundStyle(Theme.dim).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            RenameColumns(name: "Name", ext: "Ext", size: "Size", modified: "Modified", ink: Theme.dim, isBold: false)
                .frame(height: 22)
        }
        .background(Theme.deck)
    }

    private var list: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.rows) { RenameRowView(row: $0).frame(height: 20) }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topRow, anchor: .top)
            .scrollTargetBehavior(.viewAligned)
            .scrollEdgeEffectHidden()
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { pageRows = max(Int($0 / 20), 1) }
            // The first problem may be off screen, and Rename stays off until it's fixed.
            .onChange(of: session.firstProblem?.id) { _, problem in
                if let problem { reader.scrollTo(problem) }
            }
        }
    }
}

private struct RenameRowView: View {
    let row: RenameRow

    var body: some View {
        HStack(spacing: 0) {
            RenameColumns(
                name: row.entry.name, ext: row.entry.ext, size: size, modified: modified,
                symbol: "doc", ink: Theme.ink, isBold: false
            )
            lane.frame(width: 84)
            RenameColumns(
                name: row.name, ext: row.ext, size: size, modified: modified,
                symbol: row.problem == nil ? "doc" : "exclamationmark.triangle",
                ink: row.problem != nil || row.isChanged ? Theme.ink : Theme.dim,
                isBold: row.problem != nil || row.isChanged
            )
            .background(row.problem == nil ? Color.clear : Theme.line)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
    }

    private var size: String { row.entry.size.map(FileSize.format) ?? "" }
    private var modified: String { row.entry.modified.map(RowFormat.date) ?? "" }

    private var description: String {
        if let problem = row.problem { return "\(row.entry.fileName) to \(row.fileName). \(problem)" }
        return row.isChanged ? "\(row.entry.fileName) to \(row.fileName)" : "\(row.entry.fileName) stays the same"
    }

    @ViewBuilder
    private var lane: some View {
        if row.problem == nil, !row.isChanged {
            Image(systemName: "equal").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.dim)
        } else {
            Image(systemName: row.problem == nil ? "arrow.right" : "exclamationmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.keyInk)
                .frame(width: 16, height: 16)
                .background(
                    RadialGradient(colors: [Theme.keyHigh, Theme.key], center: UnitPoint(x: 0.38, y: 0.3), startRadius: 0, endRadius: 10),
                    in: Circle()
                )
                .shadow(color: .black.opacity(0.4), radius: 0.5, y: 1)
        }
    }
}

/// The same four columns as a file panel.
struct RenameColumns: View {
    let name: String
    let ext: String
    let size: String
    let modified: String
    var symbol: String?
    let ink: Color
    let isBold: Bool
    var indent: CGFloat = 0
    /// The ink for everything but the name, for rows where dim wouldn't show.
    var detailInk: Color?

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: indent)
            if let symbol {
                Image(systemName: symbol).foregroundStyle(detailInk ?? Theme.dim).frame(width: 18).accessibilityHidden(true)
            }
            Text(name).fontWeight(isBold ? .semibold : .regular).foregroundStyle(ink)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ext).frame(width: 96, alignment: .leading).lineLimit(1).foregroundStyle(detailInk ?? (symbol == nil || isBold ? ink : Theme.dim))
            Text(size).frame(width: 84, alignment: .trailing).foregroundStyle(detailInk ?? (symbol == nil ? ink : Theme.dim))
            Text(modified).frame(width: 106, alignment: .trailing).foregroundStyle(detailInk ?? (symbol == nil ? ink : Theme.dim))
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
    }
}

/// What the rename would do, in place of the status bar. Fix-it text stays neutral, because red means something gets removed.
struct RenameBar: View {
    let workspace: Workspace
    let session: RenameSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.problemCount > 0 ? "exclamationmark.triangle" : "text.cursor")
                .foregroundStyle(Theme.ink)
                .accessibilityHidden(true)
            Text(title).fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1)
            if let problem = session.firstProblem?.problem {
                Text(problem).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer()
            Button("Cancel  esc", action: workspace.cancelRename)
            // Drawn by hand, because a prominent button loses its fill in an inactive window and its ink would vanish.
            Button(action: workspace.runRename) {
                Text(run)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(nsColor: Palette.cursorInk))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Theme.cursor, in: RoundedRectangle(cornerRadius: 5))
                    .opacity(session.canRun ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!session.canRun)
        }
    }

    private var run: String {
        "Rename \(session.changedCount) file\(session.changedCount == 1 ? "" : "s")  ↩"
    }

    private var title: String {
        if session.problemCount > 0 {
            return "\(session.problemCount) name\(session.problemCount == 1 ? "" : "s") to fix"
        }
        return session.changedCount > 0 ? "\(session.changedCount) of \(session.rows.count) files change" : "No names change yet"
    }
}
