import SwiftUI

/// Shell of a file panel. Milestone 1 replaces the empty area with an `NSTableView`.
struct PanelView: View {
    let name: String
    let path: String
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                Text(name)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background(Theme.deck, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Theme.caseColor)

            HStack {
                Text(path).fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            .overlay(alignment: .top) {
                if isActive { Theme.cursor.frame(height: 2) }
            }

            ColumnHeader()
            Spacer(minLength: 0)

            HStack {
                Text("0 items")
                Spacer()
                Text("0 B")
            }
            .foregroundStyle(Theme.dim)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Theme.caseColor)
            .overlay(alignment: .top) { Theme.line.frame(height: 1) }
        }
        .background(Theme.deck)
    }
}

private struct ColumnHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Ext").frame(width: 96, alignment: .leading)
            Text("Size").frame(width: 84, alignment: .trailing)
            Text("Modified").frame(width: 106, alignment: .trailing)
        }
        .font(Theme.label)
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}
