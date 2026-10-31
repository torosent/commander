import AppKit
import CommanderCore
import SwiftUI
import UniformTypeIdentifiers

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String { rawValue.capitalized }

    /// nil follows the system, including live changes.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Preferences {
    static let themeKey = "theme"
    static let showHiddenKey = "showHiddenAtLaunch"
    static let editorKey = "defaultEditor"
    private static let sessionKey = "session"

    static var savedSession: Session? {
        UserDefaults.standard.data(forKey: sessionKey).flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
    }

    static func save(_ session: Session) {
        UserDefaults.standard.set(try? JSONEncoder().encode(session), forKey: sessionKey)
    }
}

struct SettingsView: View {
    @AppStorage(Preferences.themeKey) private var theme = AppTheme.system
    @AppStorage(Preferences.showHiddenKey) private var showHidden = false
    @AppStorage(Preferences.editorKey) private var editor = ""

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show hidden files at launch", isOn: $showHidden)
            LabeledContent("Default editor") {
                HStack {
                    Text(editor.isEmpty ? "The file's default app" : URL(filePath: editor).deletingPathExtension().lastPathComponent)
                    Button("Choose…", action: chooseEditor)
                    if !editor.isEmpty {
                        Button("Reset") { editor = "" }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseEditor() {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.application]
        chooser.directoryURL = URL(filePath: "/Applications")
        if chooser.runModal() == .OK, let url = chooser.url {
            editor = url.path
        }
    }
}
