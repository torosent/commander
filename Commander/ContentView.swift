import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            TitleStrip()
            HStack(spacing: 0) {
                PanelView(name: "Home", path: "~", isActive: true)
                KeyColumn()
                PanelView(name: "Home", path: "~", isActive: false)
            }
            StatusBar()
            CommandLine()
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.caseColor)
        .ignoresSafeArea()
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
    var body: some View {
        HStack(spacing: 12) {
            Text("Tab switches panel")
            Text("Space marks")
            Text("Type to find")
            Text("⌘K shows every command")
            Spacer()
        }
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Theme.deck)
        .overlay(alignment: .top) { Theme.rim.frame(height: 1) }
    }
}

private struct CommandLine: View {
    @State private var command = ""

    var body: some View {
        HStack(spacing: 8) {
            Text("%").foregroundStyle(Theme.dim)
            TextField("Command line", text: $command, prompt: Text(""))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }
}
