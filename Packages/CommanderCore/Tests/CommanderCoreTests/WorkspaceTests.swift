import Foundation
import Testing
@testable import CommanderCore

@MainActor
@Suite struct WorkspaceTests {
    private func workspace(_ temp: TempFolder) async -> Workspace {
        let workspace = Workspace(left: temp.url, right: temp.url)
        workspace.panels[0].refresh()
        await workspace.panels[0].loaded()
        return workspace
    }

    /// Stops as soon as the condition holds. The limit is long because disk image tests running
    /// alongside can hold up a listing for many seconds, and that mustn't read as a failure.
    private func settle(_ panel: Panel, until condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(30))
        }
        await panel.loaded()
    }

    @Test func firstRowIsTheParent() async throws {
        let temp = try TempFolder()
        try temp.file("a")
        let panel = await workspace(temp).panels[0]
        #expect(panel.rows.map(\.name) == ["..", "a"])
        #expect(panel.rows[0].isParent)
    }

    @Test func enteringThenGoingUpLandsOnTheFolder() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        try temp.file("z")
        let panel = await workspace(temp).panels[0]
        panel.setCursor(1)
        panel.openCursor()
        await panel.loaded()
        #expect(panel.location.lastPathComponent == "sub")
        panel.goUp()
        await panel.loaded()
        #expect(panel.cursorEntry?.url.standardizedFileURL.path == sub.standardizedFileURL.path)
    }

    @Test func parentRowGoesUp() async throws {
        let temp = try TempFolder()
        try temp.folder("sub")
        let panel = await workspace(temp).panels[0]
        panel.setCursor(1)
        panel.openCursor()
        await panel.loaded()
        panel.setCursor(0)
        panel.openCursor()
        await panel.loaded()
        // /var and /private/var are the same folder, so compare resolved paths.
        #expect(panel.location.resolvingSymlinksInPath().path == temp.url.resolvingSymlinksInPath().path)
    }

    @Test func backAndForwardRestoreTheCursor() async throws {
        let temp = try TempFolder()
        try temp.folder("sub")
        try temp.file("file")
        let panel = await workspace(temp).panels[0]
        panel.setCursor(2)
        let other = FileManager.default.temporaryDirectory
        panel.navigate(to: other)
        await panel.loaded()
        panel.goBack()
        await panel.loaded()
        #expect(panel.cursorEntry?.name == "file")
        #expect(panel.canGoForward)
        panel.goForward()
        await panel.loaded()
        #expect(panel.location.resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path)
    }

    @Test func navigatingClearsForwardHistory() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        let panel = await workspace(temp).panels[0]
        panel.navigate(to: a)
        panel.goBack()
        panel.navigate(to: b)
        await panel.loaded()
        #expect(!panel.canGoForward)
    }

    @Test func packagesOpenUnlessAskedOtherwise() async throws {
        let temp = try TempFolder()
        try temp.folder("Tool.app/Contents")
        let workspace = await workspace(temp)
        var opened: [String] = []
        workspace.openFile = { opened.append($0.lastPathComponent) }
        let panel = workspace.panels[0]
        panel.setCursor(1)
        panel.openCursor()
        #expect(opened == ["Tool.app"])
        panel.openCursor(asFolder: true)
        await panel.loaded()
        #expect(panel.location.lastPathComponent == "Tool.app")
    }

    @Test func hiddenFilesToggle() async throws {
        let temp = try TempFolder()
        try temp.file(".hidden")
        try temp.file("shown", bytes: 10)
        let workspace = await workspace(temp)
        let panel = workspace.panels[0]
        #expect(panel.rows.count == 2)
        #expect(panel.hiddenCount == 1)
        #expect(panel.visibleCount == 1)
        workspace.toggleHidden()
        #expect(panel.rows.count == 3)
        #expect(panel.hiddenCount == 0)
    }

    @Test func hidingMovesACursorOffAHiddenFile() async throws {
        let temp = try TempFolder()
        try temp.file(".hidden")
        try temp.file("shown")
        let workspace = await workspace(temp)
        workspace.toggleHidden()
        let panel = workspace.panels[0]
        panel.setCursor(1)
        #expect(panel.cursorEntry?.isHidden == true)
        workspace.toggleHidden()
        #expect(panel.cursorEntry?.isHidden != true)
    }

    @Test func cursorStaysOnItsFileAcrossRefresh() async throws {
        let temp = try TempFolder()
        try temp.file("b")
        let panel = await workspace(temp).panels[0]
        panel.setCursor(1)
        try temp.file("a")
        panel.refresh()
        await panel.loaded()
        #expect(panel.cursorEntry?.name == "b")
    }

    @Test func cursorHoldsItsPlaceWhenTheFileGoes() async throws {
        let temp = try TempFolder()
        let b = try temp.file("b")
        try temp.file("a")
        try temp.file("c")
        let panel = await workspace(temp).panels[0]
        panel.setCursor(2)
        try FileManager.default.removeItem(at: b)
        panel.refresh()
        await panel.loaded()
        #expect(panel.cursorEntry?.name == "c")
    }

    @Test func folderChangesAppearOnTheirOwn() async throws {
        let temp = try TempFolder()
        let panel = await workspace(temp).panels[0]
        try temp.file("arrived")
        await settle(panel) { panel.rows.contains { $0.name == "arrived" } }
        #expect(panel.rows.contains { $0.name == "arrived" })
    }

    @Test func deletedFolderMovesThePanelUp() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        let workspace = await workspace(temp)
        let panel = workspace.panels[0]
        panel.navigate(to: sub)
        await panel.loaded()
        try FileManager.default.removeItem(at: sub)
        // Watched for as it appears, because a message clears itself and a busy test run can outlast it.
        var wasTold = false
        await settle(panel) {
            wasTold = wasTold || workspace.message != nil
            return wasTold && panel.location.lastPathComponent != "sub"
        }
        #expect(panel.location.path == temp.url.path)
        #expect(wasTold)
    }

    @Test func unreadableFolderShowsAFailure() async throws {
        let temp = try TempFolder()
        let locked = try temp.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let panel = await workspace(temp).panels[0]
        panel.navigate(to: locked)
        await panel.loaded()
        #expect(panel.tab.failure == .permissionDenied)
        panel.goBack()
        await panel.loaded()
        #expect(panel.tab.failure == nil)
    }

    @Test func tabsKeepTheirOwnFolders() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        let panel = await workspace(temp).panels[0]
        panel.newTab()
        await panel.loaded()
        panel.navigate(to: sub)
        await panel.loaded()
        #expect(panel.tabs.count == 2)
        panel.nextTab(by: 1)
        await panel.loaded()
        #expect(panel.location.path == temp.url.path)
        panel.closeTab()
        await panel.loaded()
        #expect(panel.tabs.count == 1)
        #expect(panel.location.lastPathComponent == "sub")
        panel.closeTab()
        #expect(panel.tabs.count == 1)
    }

    @Test func sortingKeepsTheCursorOnItsFile() async throws {
        let temp = try TempFolder()
        try temp.file("a", bytes: 1)
        try temp.file("b", bytes: 9)
        let panel = await workspace(temp).panels[0]
        panel.setCursor(1)
        panel.sort(by: .size)
        await panel.loaded()
        panel.sort(by: .size)
        await panel.loaded()
        #expect(panel.rows[1].name == "b")
        #expect(panel.cursorEntry?.name == "a")
    }

    @Test func folderRecreatedInPlaceKeepsRefreshing() async throws {
        let temp = try TempFolder()
        let dist = try temp.folder("dist")
        let panel = await workspace(temp).panels[0]
        panel.navigate(to: dist)
        await panel.loaded()
        try FileManager.default.removeItem(at: dist)
        try temp.folder("dist")
        await settle(panel) { panel.rows.count == 1 && !panel.isLoading }
        try? await Task.sleep(for: .milliseconds(300))
        try temp.file("dist/fresh")
        await settle(panel) { panel.rows.contains { $0.name == "fresh" } }
        #expect(panel.rows.contains { $0.name == "fresh" })
    }

    @Test func steadyWritesStillRefresh() async throws {
        let temp = try TempFolder()
        let panel = await workspace(temp).panels[0]
        // Faster than the 150ms refresh delay, so a delay that restarts would never fire.
        for index in 0..<1_500 where panel.rows.count == 1 {
            try temp.file("file\(index)")
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(panel.rows.count > 1)
    }

    @Test func tabsRememberTheirCursor() async throws {
        let temp = try TempFolder()
        try temp.file("a")
        try temp.file("b")
        let panel = await workspace(temp).panels[0]
        panel.setCursor(2)
        panel.newTab()
        await panel.loaded()
        #expect(panel.cursorEntry?.name == "b")
        panel.setCursor(1)
        panel.nextTab(by: 1)
        await panel.loaded()
        #expect(panel.cursorEntry?.name == "b")
        panel.nextTab(by: 1)
        await panel.loaded()
        #expect(panel.cursorEntry?.name == "a")
    }

    @Test func deletedFolderKeepsTheTabsHistory() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        let panel = await workspace(temp).panels[0]
        panel.navigate(to: sub)
        await panel.loaded()
        try FileManager.default.removeItem(at: sub)
        await settle(panel) { panel.location.lastPathComponent != "sub" }
        #expect(panel.canGoBack)
    }

    @Test func sortingDuringALoadIsKept() async throws {
        let workspace = Workspace(left: URL(filePath: "/a"), right: URL(filePath: "/a"), source: SlowSource())
        let panel = workspace.panels[0]
        panel.refresh()
        panel.sort(by: .size)
        await panel.loaded()
        #expect(panel.tab.sort.key == .size)
        #expect(panel.rows.dropFirst().map(\.name) == ["small", "large"])
    }

    @Test func cursorStopsAtTheEnds() async throws {
        let temp = try TempFolder()
        try temp.file("a")
        let panel = await workspace(temp).panels[0]
        panel.moveCursor(by: 50)
        #expect(panel.cursorIndex == 1)
        panel.moveCursor(by: -50)
        #expect(panel.cursorIndex == 0)
    }

    @Test func goToAcceptsPathsAndReportsBadOnes() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        let file = try temp.file("plain")
        let workspace = await workspace(temp)
        #expect(await workspace.goTo(path: "/no/such/place") == "That folder does not exist.")
        #expect(await workspace.goTo(path: file.path) == "That folder does not exist.")
        #expect(await workspace.goTo(path: "  ") == "Enter a folder path.")
        #expect(await workspace.goTo(path: sub.path) == nil)
        await workspace.active.loaded()
        #expect(workspace.active.location.lastPathComponent == "sub")
        #expect(await workspace.goTo(path: "..") == nil)
        await workspace.active.loaded()
        #expect(workspace.active.location.path == temp.url.path)
        #expect(await workspace.goTo(path: "~") == nil)
        await workspace.active.loaded()
        #expect(workspace.active.location.path(percentEncoded: false).hasSuffix("/") )
    }
}

/// Slow enough for a sort to land mid-load. Honors the requested order, as a real source does.
private struct SlowSource: FileSource {
    func list(_ url: URL, sort: FileSort) async throws(ListingError) -> Listing {
        try? await Task.sleep(for: .milliseconds(50))
        let entries = [("large", Int64(9)), ("small", Int64(1))].map {
            FileEntry(url: url.appending(path: $0.0), fileName: $0.0, size: $0.1, modified: nil, isDirectory: false)
        }
        return Listing(entries: sort.sorted(entries), freeSpace: nil)
    }

    func watch(_ url: URL, onChange: @escaping @Sendable (FolderChange) -> Void) -> (any FileWatch)? { nil }
}
