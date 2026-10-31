import CommanderCore
import SwiftUI

/// Every command, filtered as you type. Sits over the window on a dim scrim.
struct CommandPalette: View {
    let workspace: Workspace

    @State private var query = ""
    @State private var chosen = 0
    @FocusState private var isFocused: Bool

    private var hits: [AppCommand] { workspace.commands(matching: query) }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture(perform: workspace.closePalette)
                .accessibilityHidden(true)
            sheet.padding(.top, 72)
        }
        .onAppear { isFocused = true }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            TextField("Run a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .padding(.horizontal, 12)
                .frame(height: 40)
                .overlay {
                    RoundedRectangle(cornerRadius: 5).stroke(Theme.cursor, lineWidth: 2).padding(3)
                }
                .onChange(of: query) { chosen = 0 }
                .onSubmit { run(chosen) }
                .onExitCommand(perform: workspace.closePalette)
                .onKeyPress(.downArrow) { step(1) }
                .onKeyPress(.upArrow) { step(-1) }
            Theme.line.frame(height: 1)
            list
        }
        .frame(width: 520)
        .background(Theme.deck, in: RoundedRectangle(cornerRadius: 8))
        // Grouped first, or each row casts its own shadow on the rows below.
        .compositingGroup()
        .shadow(color: .black.opacity(0.42), radius: 21, y: 18)
    }

    private var list: some View {
        let hits = hits
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if hits.isEmpty {
                        Text("No command matches.").foregroundStyle(Theme.dim).frame(height: 56)
                    }
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, command in
                        Button { run(index) } label: {
                            row(command, isChosen: index == chosen)
                        }
                        .buttonStyle(.plain)
                        .disabled(!command.isEnabled)
                        .accessibilityAddTraits(index == chosen ? .isSelected : [])
                    }
                }
                .padding(4)
            }
            .scrollEdgeEffectHidden()
            .frame(height: min(CGFloat(max(hits.count, 2)) * 28 + 8, 372))
            .onChange(of: chosen) {
                if hits.indices.contains(chosen) { reader.scrollTo(hits[chosen].id) }
            }
        }
    }

    private func row(_ command: AppCommand, isChosen: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: command.symbol).frame(width: 16).accessibilityHidden(true)
            Text(command.title)
            Spacer()
            Text(command.keys).opacity(0.7)
        }
        .foregroundStyle(isChosen ? Color(nsColor: Palette.cursorInk) : command.isEnabled ? Theme.ink : Theme.dim)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(isChosen ? Theme.cursor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }

    private func step(_ by: Int) -> KeyPress.Result {
        let count = hits.count
        if count > 0 { chosen = (chosen + by + count) % count }
        return .handled
    }

    private func run(_ index: Int) {
        let hits = hits
        guard hits.indices.contains(index), hits[index].isEnabled else { return }
        workspace.closePalette()
        // Focus has to reach the table first, for commands that go through the responder chain.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { hits[index].run() }
    }
}
