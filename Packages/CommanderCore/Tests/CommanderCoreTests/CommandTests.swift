import Foundation
import Testing
@testable import CommanderCore

@MainActor
@Suite struct CommandTests {
    private func setup(_ temp: TempFolder) async throws -> Workspace {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        return app
    }

    @Test func thePaletteFiltersByTitleAndKeys() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        #expect(app.commands(matching: "").count == app.commands.count)
        #expect(app.commands(matching: "sort").count == 4)
        #expect(app.commands(matching: "sort size").map(\.title) == ["Sort by Size"])
        #expect(app.commands(matching: "F5").map(\.title) == ["Copy to Other Panel"])
        #expect(app.commands(matching: "zzz").isEmpty)
    }

    @Test func titlesStartingWithTheQueryComeFirst() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        #expect(app.commands(matching: "mark").first?.title == "Mark or Unmark")
        #expect(app.commands(matching: "copy").first?.title == "Copy to Other Panel")
    }

    @Test func commandIDsAreUnique() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let ids = app.commands.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyBuiltCommandInTheKeyboardMapIsListed() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let titles = Set(app.commands.map(\.title))
        for title in [
            "View Beside", "Edit", "Copy to Other Panel", "Move to Other Panel", "New Folder", "Move to Trash",
            "Rename", "Undo Rename", "Show Actions", "Go to Path", "Open Terminal Here", "Copy Path",
            "Go to Command Line", "Show Hidden Files", "Mark All", "Next Tab", "Sort by Modified",
        ] {
            #expect(titles.contains(title), "\(title)")
        }
    }

    @Test func commandsThatNeedASelectionSaySo() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        #expect(app.commands.first { $0.title == "Copy to Other Panel" }?.isEnabled == false)
        try temp.file("a/one")
        app.active.refresh()
        await app.active.loaded()
        app.active.setCursor(1)
        #expect(app.commands.first { $0.title == "Copy to Other Panel" }?.isEnabled == true)
    }

    @Test func aCommandRunsThroughThePalette() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.commands.first { $0.title == "Go to Path" }?.run()
        #expect(app.isGoingToPath)
    }

    @Test func commandsStayEnabledWhileThePaletteIsOpen() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try temp.file("a/one")
        app.active.refresh()
        await app.active.loaded()
        app.active.setCursor(1)
        app.openPalette()
        #expect(app.commands.first { $0.title == "Copy to Other Panel" }?.isEnabled == true)
    }

    @Test func thePaletteHoldsOffOtherShortcuts() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.openPalette()
        #expect(app.isTyping)
        app.closePalette()
        #expect(!app.isTyping)
    }

    @Test func editHandsOverFilesOnly() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        var edited: URL?
        app.desktop.edit = { edited = $0 }
        app.edit()
        #expect(edited == nil)
        #expect(app.message == "Move the cursor to a file to edit it.")
        let file = try temp.file("a/one")
        app.active.refresh()
        await app.active.loaded()
        app.active.setCursor(1)
        app.edit()
        #expect(edited?.lastPathComponent == file.lastPathComponent)
    }

    @Test func aPackageIsntHandedToTheEditor() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        var edited: URL?
        app.desktop.edit = { edited = $0 }
        try temp.folder("a/Thing.app")
        app.active.refresh()
        await app.active.loaded()
        app.active.setCursor(1)
        #expect(app.active.cursorEntry?.isPackage == true)
        app.edit()
        #expect(edited == nil)
    }

    @Test func copyPathTakesTheSelectionOrElseTheFolder() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        var copied = ""
        app.desktop.copyText = { copied = $0 }
        app.copyPath()
        #expect(copied == app.active.location.path)
        try temp.file("a/one")
        try temp.file("a/two")
        app.active.refresh()
        await app.active.loaded()
        app.active.markAll()
        app.copyPath()
        #expect(copied.split(separator: "\n").count == 2)
        #expect(app.message == "Copied 2 paths.")
    }

    @Test func tabGoesToTheViewerRatherThanTheHiddenPanel() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.toggleViewer()
        let tick = app.viewerFocusTick
        app.switchPanel()
        #expect(app.activeIndex == 0)
        #expect(app.viewerFocusTick == tick + 1)
        app.closeViewer()
        app.switchPanel()
        #expect(app.activeIndex == 1)
    }

    // MARK: Command line

    @Test func aCommandRunsInTheActiveFolderAndItsOutputOpens() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.runCommandLine("pwd")
        await app.commandDone()
        let text = app.viewer?.file?.rows(from: 0, count: 9, columns: 500).map(\.text).last
        #expect(text?.hasSuffix("/a") == true)
        #expect(app.viewer?.title == "Output of pwd")
        #expect(app.message == "Finished pwd.")
        #expect(app.runningCommand == nil)
        #expect(app.viewer?.url.map(FileNames.exists) == false)
    }

    @Test func aQuietCommandOpensNothingAndChangesShow() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.runCommandLine("touch made")
        await app.commandDone()
        await app.active.loaded()
        #expect(app.viewer == nil)
        #expect(app.active.rows.contains { $0.name == "made" })
    }

    @Test func aFailureGivesItsStatusAndErrors() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.runCommandLine("echo broken >&2; exit 3")
        await app.commandDone()
        #expect(app.message == "echo broken >&2; exit 3 exited with status 3.")
        #expect(app.viewer?.file?.rows(from: 0, count: 9, columns: 80).last?.text == "broken")
    }

    @Test func cdMovesThePanel() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try temp.folder("a/sub dir")
        app.runCommandLine("cd \"sub dir\"")
        await app.commandDone()
        #expect(app.active.location.lastPathComponent == "sub dir")
        app.runCommandLine("cd nowhere")
        await app.commandDone()
        #expect(app.message == "That folder does not exist.")
    }

    @Test func cdTakesAnEscapedSpace() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try temp.folder("a/sub dir")
        app.runCommandLine("cd sub\\ dir")
        await app.commandDone()
        #expect(app.active.location.lastPathComponent == "sub dir")
    }

    @Test func aCompoundCdGoesToTheShell() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try temp.folder("a/sub")
        app.runCommandLine("cd sub && touch made")
        await app.commandDone()
        #expect(FileNames.exists(temp.url.appending(path: "a/sub/made")))
        #expect(app.active.location.lastPathComponent == "a")
    }

    @Test func aRunningCommandCanBeStopped() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.runCommandLine("exec sleep 30")
        #expect(app.runningCommand == "exec sleep 30")
        app.runCommandLine("echo second")
        #expect(app.message == "A command is already running.")
        try await Task.sleep(for: .milliseconds(300))
        app.stopCommand()
        await app.commandDone()
        #expect(app.runningCommand == nil)
        #expect(app.message == "Stopped exec sleep 30.")
    }

    private func isRunning(_ pattern: String) throws -> Bool {
        let search = Process()
        search.executableURL = URL(filePath: "/usr/bin/pgrep")
        search.arguments = ["-f", pattern]
        search.standardOutput = FileHandle.nullDevice
        try search.run()
        search.waitUntilExit()
        return search.terminationStatus == 0
    }

    @Test func stoppingAlsoStopsWhatTheShellStarted() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        // A unique length, so this finds its own sleep and no other test's.
        let sleep = "sleep 41.\(Int.random(in: 1000...9999))"
        app.runCommandLine("\(sleep); echo done")
        // Anchored, because the shell's own command line holds these words too.
        while try !isRunning("^\(sleep)") { try await Task.sleep(for: .milliseconds(20)) }
        app.stopCommand()
        await app.commandDone()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try !isRunning("^\(sleep)"))
    }

    @Test func stoppingWithNothingRunningDoesNothing() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.stopCommand()
        app.runCommandLine("echo hello")
        await app.commandDone()
        #expect(app.message == "Finished echo hello.")
    }

    @Test func aBlankLineDoesNothing() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.runCommandLine("   ")
        #expect(app.runningCommand == nil)
    }
}
