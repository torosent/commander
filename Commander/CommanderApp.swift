import SwiftUI

@main
struct CommanderApp: App {
    var body: some Scene {
        Window("Commander", id: "main") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
    }
}
