import AppKit
import CommanderCore
import UniformTypeIdentifiers

extension Desktop {
    /// The system's side of each hand-off.
    static var app: Desktop {
        var desktop = Desktop()
        desktop.edit = { url in
            guard let editor = Preferences.chosenApp(Preferences.editorKey) else {
                NSWorkspace.shared.open(url)
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        }
        desktop.openTerminal = { folder in
            let terminal = Preferences.chosenApp(Preferences.terminalKey)
                ?? NSWorkspace.shared.urlForApplication(toOpen: .unixExecutable)
                ?? URL(filePath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        }
        desktop.copyText = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        desktop.copyFiles = { urls in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(urls as [NSURL])
        }
        desktop.pastedFiles = { Pasteboard.fileURLs() }
        desktop.quickLook = QuickLook.toggle
        desktop.showActions = { NSApp.sendAction(#selector(KeyTable.showActions(_:)), to: nil, from: nil) }
        desktop.undo = { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
        desktop.openFullDiskAccess = FullDiskAccess.open
        return desktop
    }
}
