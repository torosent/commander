import CommanderCore
import SwiftUI

/// The column between the panels. Copy stays on the vertical centre at every window height.
struct KeyColumn: View {
    let workspace: Workspace

    private var panel: Panel { workspace.active }
    private var nothingSelected: Bool { panel.selectionCount == 0 }
    private var arrow: String { workspace.activeIndex == 0 ? "arrow.right" : "arrow.left" }

    var body: some View {
        // GeometryReader takes the offered height, so the keys can never push the window taller.
        GeometryReader { geometry in
            // Full-size keys need about 711pt: 316 for each half, plus Copy and the padding.
            let compact = geometry.size.height < 720
            column(compact: compact)
                .frame(width: 84, height: geometry.size.height)
                .clipped()
        }
        .frame(width: 84)
        .overlay(alignment: .leading) { Theme.rim.frame(width: 1) }
        .overlay(alignment: .trailing) { Theme.rim.frame(width: 1) }
    }

    private func column(compact: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: compact ? 5 : 6) {
                SelectionSummary(
                    count: panel.selectionCount, size: panel.selectionSize,
                    isPartial: panel.isMeasuring, arrow: arrow, compact: compact
                )
                Spacer(minLength: 0)
                key("Compress", "⌘⇧P", "archivebox", disabled: nothingSelected, compact: compact)
                // Stays off until archives exist in milestone 6.
                key("Extract", "⌘⇧U", "archivebox.fill", disabled: true, compact: compact)
                rule
                key("View", "F3", "eye", compact: compact, action: workspace.toggleViewer)
                key("Edit", "F4", "pencil", compact: compact, action: workspace.edit)
            }
            .frame(maxHeight: .infinity)

            key("Copy", "F5", "doc.on.doc", tone: .copy, disabled: nothingSelected, compact: compact) { workspace.begin(.copy) }
                .padding(.vertical, 6)

            VStack(spacing: compact ? 5 : 6) {
                key("Move", "F6", arrow, tone: .move, disabled: nothingSelected, compact: compact) { workspace.begin(.move) }
                key("New", "F7", "plus", compact: compact) { panel.beginNewFolder() }
                key("Trash", "F8", "trash", tone: .trash, disabled: nothingSelected, compact: compact) { workspace.begin(.trash) }
                rule
                key("Rename", "⌘⇧R", "character.cursor.ibeam", disabled: nothingSelected, compact: compact, action: workspace.beginRename)
                key("Compare", "⌘⇧D", "rectangle.split.2x1", compact: compact)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.vertical, 8)
    }

    /// A key stays down while its operation is previewed or running.
    private func isHeld(_ title: String) -> Bool {
        if title == "View" { return workspace.viewer != nil }
        guard let kind = workspace.pending?.preview.kind ?? workspace.jobs.current?.kind else { return false }
        switch kind {
        case .copy: return title == "Copy"
        case .move: return title == "Move"
        case .trash, .delete: return title == "Trash"
        case .rename: return title == "Rename"
        }
    }

    private var rule: some View {
        Theme.line.frame(width: 44, height: 1).padding(.vertical, 1)
    }

    private func key(
        _ title: String, _ shortcut: String, _ symbol: String,
        tone: KeyTone = .neutral, disabled: Bool = false, compact: Bool,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let action { action() } else { workspace.notBuilt(title) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .accessibilityHidden(true)
        }
        .buttonStyle(DomeKeyStyle(title: "\(title) \(shortcut)", tone: tone, compact: compact, isHeld: isHeld(title)))
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityHint(shortcut)
    }
}

private struct SelectionSummary: View {
    let count: Int
    let size: Int64
    let isPartial: Bool
    let arrow: String
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 2 : 5) {
            Text(count.formatted()).font(.system(size: 20, weight: .semibold).monospacedDigit())
            if !compact {
                Text(FileSize.format(size) + (isPartial ? "…" : "")).font(Theme.label).foregroundStyle(Theme.dim)
            }
            Image(systemName: arrow).font(.system(size: 15, weight: .semibold))
        }
        .padding(.bottom, compact ? 4 : 8)
        .frame(width: 60)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            count == 0 ? "Nothing selected" : "\(count) selected, \(isPartial ? "at least " : "")\(FileSize.format(size))"
        )
    }
}

enum KeyTone {
    case neutral, copy, move, trash

    var fill: Color {
        switch self {
        case .neutral: Theme.key
        case .copy: Theme.rgb(0x3FA34D)
        case .move: Theme.rgb(0xF2B705)
        case .trash: Theme.rgb(0xD8412F)
        }
    }

    var highlight: Color {
        switch self {
        case .neutral: Theme.keyHigh
        case .copy: Theme.rgb(0x58C168)
        case .move: Theme.rgb(0xFFD24E)
        case .trash: Theme.rgb(0xEC6A59)
        }
    }

    var ink: Color {
        switch self {
        case .neutral: Theme.keyInk
        case .copy: Theme.rgb(0x0D240F)
        case .move: Theme.rgb(0x2F2300)
        case .trash: .white
        }
    }
}

/// A moulded key: a lit dome at rest, sunk by 2pt while pressed.
struct DomeKeyStyle: ButtonStyle {
    let title: String
    let tone: KeyTone
    var compact = false
    var isHeld = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || isHeld
        let size: CGFloat = compact ? 30 : 34
        VStack(spacing: 4) {
            configuration.label
                .foregroundStyle(tone.ink)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(RadialGradient(
                            colors: [tone.highlight, tone.fill],
                            center: UnitPoint(x: 0.38, y: 0.3),
                            startRadius: 0,
                            endRadius: 24
                        ))
                        .overlay {
                            Circle().strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .center),
                                lineWidth: 1
                            )
                        }
                        .shadow(color: .black.opacity(pressed ? 0.5 : 0.45), radius: pressed ? 0.5 : 2, y: pressed ? 0 : 2)
                }
                .offset(y: pressed ? 2 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: pressed)
            if !compact {
                Text(title)
                    .font(.system(size: 10.5).monospacedDigit())
                    .tracking(-0.1)
                    .lineLimit(1)
                    .foregroundStyle(Theme.dim)
                    .fixedSize()
            }
        }
        .frame(width: 82)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.38)
    }
}
