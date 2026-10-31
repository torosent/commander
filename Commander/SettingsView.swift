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
    static let terminalKey = "terminalApp"
    private static let sessionKey = "session"

    /// The app chosen in Settings, unless it has since been removed.
    static func chosenApp(_ key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path)
    }

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
    @AppStorage(Preferences.terminalKey) private var terminal = ""

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Show hidden files at launch", isOn: $showHidden)
            appChoice("Default editor", fallback: "The file's default app", path: $editor)
            appChoice("Terminal", fallback: "The system's default terminal", path: $terminal)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func appChoice(_ title: String, fallback: String, path: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                Text(path.wrappedValue.isEmpty ? fallback : URL(filePath: path.wrappedValue).deletingPathExtension().lastPathComponent)
                Button("Choose…") { chooseApp(for: path) }
                if !path.wrappedValue.isEmpty {
                    Button("Reset") { path.wrappedValue = "" }
                }
            }
        }
    }

    private func chooseApp(for path: Binding<String>) {
        let chooser = NSOpenPanel()
        chooser.allowedContentTypes = [.application]
        chooser.directoryURL = URL(filePath: "/Applications")
        if chooser.runModal() == .OK, let url = chooser.url {
            path.wrappedValue = url.path
        }
    }
}
