import CommanderCore
import SwiftUI

/// Two folders side by side, with a key per row saying what a sync would do.
/// Nothing here changes anything until Sync, so this screen is the sync's preview.
struct CompareView: View {
    let workspace: Workspace
    @Bindable var session: CompareSession

    @FocusState private var isFocused: Bool
    @State private var diff: DiffRequest?

    var body: some View {
        VStack(spacing: 0) {
            options
            HStack(spacing: 0) {
                head(session.left)
                Theme.caseColor.frame(width: 84)
                head(session.right)
            }
            .frame(height: 50)
            ZStack(alignment: .top) {
                HStack(spacing: 0) {
                    Theme.deck
                    Theme.caseColor.frame(width: 84)
                    Theme.deck
                }
                content
            }
        }
        .font(Theme.body)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: [.down, .repeat], action: handle)
        .onAppear { DispatchQueue.main.async { isFocused = true } }
        .overlay {
            if let diff {
                DiffView(request: diff) {
                    self.diff = nil
                    isFocused = true
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = session.failure {
            message(failure)
        } else if session.isComparing, session.rows.isEmpty {
            message("Comparing… \(session.scanned) items")
        } else if session.visible.isEmpty {
            message(session.onlyDifferences ? "No differences." : "Both folders are empty.")
        } else {
            GeometryReader { geometry in
                list.frame(height: (geometry.size.height / 20).rounded(.down) * 20)
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.visible.indices, id: \.self) { index in
                        let row = session.visible[index]
                        CompareRowView(
                            row: row, isByContent: session.mode == .content, isCursor: index == session.cursor, onSelect: {
                                session.cursor = index
                                isFocused = true
                            },
                            onLane: {
                                session.cursor = index
                                isFocused = true
                                session.choose(row.left == nil || row.action == .toRight && row.right != nil ? .toLeft : .toRight)
                            }
                        )
                        .frame(height: 20)
                    }
                }
            }
            .scrollEdgeEffectHidden()
            .onChange(of: session.cursor) { _, cursor in
                reader.scrollTo(cursor)
            }
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // Anything held with a modifier is a shortcut meant for somewhere else.
        guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
        // Holding an arrow key moves on, but holding Return mustn't sync twice.
        if press.phase == .repeat, ![.upArrow, .downArrow, .pageUp, .pageDown].contains(press.key) { return .handled }
        switch press.key {
        case .upArrow: session.moveCursor(by: -1)
        case .downArrow: session.moveCursor(by: 1)
        case .pageUp: session.moveCursor(by: -30)
        case .pageDown: session.moveCursor(by: 30)
        case .rightArrow: session.choose(.toRight)
        case .leftArrow: session.choose(.toLeft)
        case .return: workspace.runSync()
        case .escape:
            if workspace.report != nil { workspace.dismissReport() } else { workspace.closeCompare() }
        case .space: showDiff()
        default:
            switch press.characters.lowercased() {
            case "1": session.mode = .nameAndDate
            case "2": session.mode = .size
            case "3": session.mode = .content
            case "d": session.onlyDifferences.toggle()
            case "a": session.setAllowsDeletions(!session.allowsDeletions)
            case "-": session.choose(.skip)
            case "x": session.choose(.trash)
            default: return .ignored
            }
        }
        return .handled
    }

    private func showDiff() {
        guard session.visible.indices.contains(session.cursor) else { return }
        let row = session.visible[session.cursor]
        guard let left = row.left, let right = row.right, !left.isFolder, !right.isFolder else { return }
        diff = DiffRequest(left: left.url, right: right.url, name: row.name)
    }

    private var options: some View {
        HStack(spacing: 12) {
            Text("Compare by")
            Picker("Compare by", selection: $session.mode) {
                Text("Name and date 1").tag(CompareMode.nameAndDate)
                Text("Size 2").tag(CompareMode.size)
                Text("Content 3").tag(CompareMode.content)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Show", selection: $session.onlyDifferences) {
                Text("All files").tag(false)
                Text("Differences D").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Toggle("Allow deletions  A", isOn: Binding(get: { session.allowsDeletions }, set: session.setAllowsDeletions))
                .toggleStyle(.checkbox)
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(Theme.caseColor)
        .overlay(alignment: .bottom) { Theme.rim.frame(height: 1) }
    }

    private func head(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(folder.lastPathComponent).fontWeight(.semibold).foregroundStyle(Theme.ink)
                Text(folder.deletingLastPathComponent().path).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            RenameColumns(name: "Name", ext: "", size: "Size", modified: "Modified", ink: Theme.dim, isBold: false)
                .frame(height: 22)
        }
        .background(Theme.deck)
    }
}

private struct CompareRowView: View {
    let row: CompareRow
    let isByContent: Bool
    let isCursor: Bool
    let onSelect: () -> Void
    let onLane: () -> Void

    private var ink: Color { isCursor ? Color(nsColor: Palette.cursorInk) : Theme.ink }

    var body: some View {
        HStack(spacing: 0) {
            side(row.left, receives: row.action == .toLeft)
                .background(wash(for: row.left))
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
            // In a ZStack, because a lane with nothing to show would otherwise take no width
            // and the right side would slide over the middle column.
            ZStack {
                Color.clear
                lane
            }
                .frame(width: 84, height: 20)
                .background(isCursor ? Theme.cursor : .clear)
                .contentShape(Rectangle())
                .onTapGesture(perform: onLane)
            side(row.right, receives: row.action == .toRight)
                .background(wash(for: row.right))
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelect)
        }
        .background(isCursor ? Theme.cursor : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .accessibilityAddTraits(isCursor ? .isSelected : [])
    }

    private var description: String {
        let action = switch row.action {
        case .toRight: "copies to the right"
        case .toLeft: "copies to the left"
        case .trash: "goes to Trash"
        case .skip: "skipped"
        case .none: row.verdict == .same ? "identical" : "left alone"
        }
        return "\(row.name), \(action)"
    }

    private func wash(for side: CompareSide?) -> Color {
        guard row.action == .trash, side != nil, !isCursor else { return .clear }
        return Color(nsColor: Palette.removeWash)
    }

    private func side(_ side: CompareSide?, receives: Bool) -> some View {
        let isDim = row.verdict == .same && !row.isHeader
        return RenameColumns(
            name: side?.name ?? "",
            ext: tag(side),
            size: side.flatMap { $0.isFolder ? nil : FileSize.format($0.size) } ?? "",
            modified: side.map { row.isHeader ? "" : RowFormat.date($0.modified) } ?? (receives ? "missing" : ""),
            symbol: side == nil ? "" : "doc",
            ink: isCursor ? ink : isDim ? Theme.dim : ink,
            isBold: row.isHeader || (!isDim && side != nil),
            fileIcon: side.map { FileIconView(name: $0.name, url: $0.url, modified: $0.modified, isFolder: $0.isFolder, isDim: isDim) },
            indent: CGFloat(row.depth) * 14,
            detailInk: isCursor ? ink : nil
        )
    }

    private func tag(_ side: CompareSide?) -> String {
        guard side != nil else { return "" }
        return switch row.verdict {
        case .clash: "file and folder"
        case .unreadable: "can't be read"
        case .nameTaken: "name taken"
        case .different where isByContent: "contents differ"
        default: ""
        }
    }

    @ViewBuilder
    private var lane: some View {
        switch row.action {
        case .toRight: dome("arrow.right", fill: Theme.goFill)
        case .toLeft: dome("arrow.left", fill: Theme.goFill)
        case .trash: dome("trash", fill: Theme.removeFill)
        case .skip: mark("minus")
        case .none:
            if row.verdict == .same, !row.isHeader {
                mark("equal")
            } else if [.clash, .unreadable, .nameTaken].contains(row.verdict) {
                mark("exclamationmark")
            }
        }
    }

    private func mark(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(isCursor ? ink : Theme.dim)
    }

    private func dome(_ symbol: String, fill: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(fill, in: Circle())
            .shadow(color: .black.opacity(0.4), radius: 0.5, y: 1)
    }
}

/// What a sync would do, and the only way to start one.
struct CompareBar: View {
    let workspace: Workspace
    let session: CompareSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.split.2x1").foregroundStyle(Theme.ink).accessibilityHidden(true)
            Text(title).fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1)
            if session.toTrash > 0 {
                Image(systemName: "trash").foregroundStyle(Theme.removeText).accessibilityHidden(true)
                Text("\(session.toTrash) to Trash").foregroundStyle(Theme.removeText).lineLimit(1)
            }
            if session.itemCount > 0 {
                Text("\(FileSize.format(session.bytes)) · \(session.skipped) skipped").lineLimit(1)
            }
            Spacer()
            // A sync's result has to show here, or a refused file would go unnoticed.
            Text(news ?? "Arrows set direction · Minus skips · X trashes · Space shows differences")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(news == nil ? Theme.dim : Theme.ink)
            if workspace.report != nil {
                Button("Dismiss  esc", action: workspace.dismissReport)
            } else {
                Button("Close  esc", action: workspace.closeCompare)
            }
            Button(run, action: workspace.runSync)
                .buttonStyle(.borderedProminent)
                .tint(session.toTrash > 0 ? Theme.removeFill : Theme.goFill)
                .disabled(!session.canSync)
        }
    }

    private var news: String? {
        session.notice ?? workspace.report?.summary ?? workspace.message
    }

    private var run: String {
        "Sync \(session.itemCount) item\(session.itemCount == 1 ? "" : "s")  ↩"
    }

    private var title: String {
        if session.isComparing { return "Comparing…" }
        guard session.itemCount > 0 else { return "Nothing to sync" }
        return "\(session.toRight) to \(session.right.lastPathComponent) · \(session.toLeft) to \(session.left.lastPathComponent)"
    }
}

struct DiffRequest {
    let left: URL
    let right: URL
    let name: String
}

/// Two text files, lined up. Changes are marked in neutral, because here nothing is being copied or removed.
private struct DiffView: View {
    let request: DiffRequest
    let onClose: () -> Void

    @State private var rows: [TextDiff.Row] = []
    @State private var problem: String?
    @State private var isLoading = true
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3).ignoresSafeArea().onTapGesture(perform: onClose).accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack {
                    Text(request.name).fontWeight(.semibold).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(isLoading ? "Comparing lines…" : "\(rows.count { $0.isChanged }) lines differ").foregroundStyle(Theme.dim)
                    Spacer()
                    Button("Close  esc", action: onClose)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                Theme.line.frame(height: 1)
                if let problem {
                    Text(problem).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { DiffLine(row: $0) }
                        }
                    }
                    .scrollEdgeEffectHidden()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.deck, in: RoundedRectangle(cornerRadius: 8))
            .compositingGroup()
            .shadow(color: .black.opacity(0.42), radius: 21, y: 18)
            .padding(40)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onKeyPress(.space) {
            onClose()
            return .handled
        }
        .onAppear { DispatchQueue.main.async { isFocused = true } }
        .task {
            let (left, right) = (request.left, request.right)
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[TextDiff.Row], TextDiff.Failure> in
                do throws(TextDiff.Failure) {
                    return .success(try TextDiff.rows(left, right))
                } catch {
                    return .failure(error)
                }
            }.value
            isLoading = false
            switch result {
            case .success(let found): rows = found
            case .failure(.tooLarge): problem = "These files are too large to show line by line."
            case .failure(.tooDifferent): problem = "These files differ too much to show line by line."
            case .failure(.notText): problem = "Only text files can be shown line by line."
            }
        }
    }
}

private struct DiffLine: View {
    let row: TextDiff.Row

    var body: some View {
        HStack(spacing: 0) {
            cell(row.left)
            Theme.line.frame(width: 1)
            cell(row.right)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(row.isChanged ? Theme.line : .clear)
    }

    private func cell(_ text: String?) -> some View {
        Text(text ?? "")
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
    }
}
