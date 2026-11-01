import Foundation
import Testing
@testable import CommanderCore

@Test func globsMatchNames() {
    let glob = Glob("*.js, *.TS; re?dme")
    #expect(glob.matches("app.js"))
    #expect(glob.matches("app.ts"))
    #expect(glob.matches("readme"))
    #expect(!glob.matches("app.json"))
}

@Test func globsIgnoreUnicodeForm() {
    #expect(Glob("caf\u{E9}*").matches("cafe\u{301}.txt"))
    #expect(Glob("cafe\u{301}*").matches("caf\u{E9}.txt"))
}

@Test func emptyGlobMatchesNothing() {
    #expect(!Glob(" , ").matches("anything"))
}

@MainActor
@Suite struct MarkingTests {
    private func panel(_ temp: TempFolder, in workspace: inout Workspace?) async -> Panel {
        let made = Workspace(left: temp.url, right: temp.url)
        workspace = made
        made.panels[0].refresh()
        await made.panels[0].loaded()
        return made.panels[0]
    }

    /// Files `a` to `f`, each one byte per letter position, under the ".." row.
    private func rangeFolder(_ temp: TempFolder, in workspace: inout Workspace?) async throws -> Panel {
        for (size, name) in ["a", "b", "c", "d", "e", "f"].enumerated() { try temp.file(name, bytes: size + 1) }
        return await panel(temp, in: &workspace)
    }

    private func marked(_ panel: Panel) -> [String] {
        panel.selectionEntries.map(\.name).filter { _ in panel.markedCount > 0 }
    }

    @Test func aRangeMarksFromTheCursorToTheTarget() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(2)
        panel.extendMarks(to: 4)
        #expect(marked(panel) == ["b", "c", "d"])
        #expect(panel.cursorEntry?.name == "d")
        #expect(panel.markedCount == 3)
        #expect(panel.markedSize == 2 + 3 + 4)
    }

    @Test func pullingARangeBackUnmarksAndCrossesItsStart() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(3)
        panel.extendMarks(to: 5)
        panel.extendMarks(to: 4)
        #expect(marked(panel) == ["c", "d"])
        panel.extendMarks(to: 2)
        #expect(marked(panel) == ["b", "c"])
        #expect(panel.markedSize == 2 + 3)
    }

    @Test func aRangeLeavesEarlierMarksAlone() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(4)
        panel.toggleMark()
        panel.setCursor(3)
        panel.extendMarks(to: 5)
        #expect(marked(panel) == ["c", "d", "e"])
        panel.extendMarks(to: 3)
        #expect(marked(panel) == ["c", "d"])
        #expect(panel.markedCount == 2)
    }

    @Test func aPlainMoveEndsTheRangeAndKeepsItsMarks() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(1)
        panel.extendMarks(to: 2)
        panel.setCursor(5)
        panel.extendMarks(to: 6)
        #expect(marked(panel) == ["a", "b", "e", "f"])
        panel.extendMarks(to: 5)
        #expect(marked(panel) == ["a", "b", "e"])
    }

    @Test func aRangeLeavesTheParentRowOut() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(2)
        panel.extendMarks(to: 0)
        #expect(marked(panel) == ["a", "b"])
        #expect(panel.cursorEntry?.isParent == true)
        #expect(panel.markedCount == 2)
    }

    @Test func aRangeStopsAtTheEnds() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(5)
        panel.extendMarks(to: .max - 1)
        #expect(marked(panel) == ["e", "f"])
        #expect(panel.cursorEntry?.name == "f")
    }

    @Test func bulkMarkingEndsARange() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(1)
        panel.extendMarks(to: 3)
        panel.clearMarks()
        panel.extendMarks(to: 4)
        #expect(marked(panel) == ["c", "d"])
    }

    @Test func aRefreshDuringARangeKeepsItsMarks() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(1)
        panel.extendMarks(to: 2)
        try temp.file("0-first")
        panel.refresh()
        await panel.loaded()
        panel.extendMarks(to: panel.cursorIndex + 1)
        #expect(marked(panel) == ["a", "b", "c"])
    }

    @Test func aMarkCanBeToggledWithoutMoving() async throws {
        let temp = try TempFolder()
        var workspace: Workspace?
        let panel = try await rangeFolder(temp, in: &workspace)
        panel.setCursor(2)
        panel.toggleMark(advancing: false)
        #expect(panel.cursorEntry?.name == "b")
        #expect(panel.markedCount == 1)
        panel.toggleMark(advancing: false)
        #expect(panel.markedCount == 0)
    }

    @Test func spaceMarksAndMovesDown() async throws {
        let temp = try TempFolder()
        try temp.file("a", bytes: 10)
        try temp.file("b", bytes: 5)
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.setCursor(1)
        panel.toggleMark()
        #expect(panel.cursorEntry?.name == "b")
        #expect(panel.markedCount == 1)
        #expect(panel.markedSize == 10)
        panel.toggleMark()
        #expect(panel.markedSize == 15)
        panel.setCursor(1)
        panel.toggleMark()
        #expect(panel.markedCount == 1)
    }

    @Test func parentRowCannotBeMarked() async throws {
        let temp = try TempFolder()
        try temp.file("a")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.toggleMark()
        #expect(panel.markedCount == 0)
        #expect(panel.cursorEntry?.name == "a")
    }

    @Test func selectionFallsBackToTheCursor() async throws {
        let temp = try TempFolder()
        try temp.file("a", bytes: 7)
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        #expect(panel.selectionCount == 0)
        panel.setCursor(1)
        #expect(panel.selectionCount == 1)
        #expect(panel.selectionSize == 7)
    }

    @Test func markAllSkipsTheParentAndInvertSkipsFolders() async throws {
        let temp = try TempFolder()
        try temp.folder("dir")
        try temp.file("a")
        try temp.file("b")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.markAll()
        #expect(panel.markedCount == 3)
        panel.invertMarks()
        #expect(panel.markedCount == 1)
        #expect(panel.isMarked(panel.rows[1]))
        panel.clearMarks()
        #expect(panel.markedCount == 0)
    }

    @Test func patternPreviewsUntilApplied() async throws {
        let temp = try TempFolder()
        try temp.file("a.js")
        try temp.file("b.js")
        try temp.file("c.md")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        panel.setCursor(1)
        app.beginPattern(marks: true)
        await panel.marksCounted()
        #expect(app.patternBar?.text == "*.js")
        #expect(panel.markedCount == 2)
        #expect(panel.tab.marked.isEmpty)
        app.updatePattern("*.md")
        await panel.marksCounted()
        #expect(panel.markedCount == 1)
        app.applyPattern()
        #expect(panel.tab.marked.count == 1)
        #expect(app.patternBar == nil)
        #expect(panel.isMarked(panel.rows[3]))
    }

    @Test func cancellingAPatternLeavesMarksAlone() async throws {
        let temp = try TempFolder()
        try temp.file("a.js")
        try temp.file("b.js")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        panel.setCursor(1)
        panel.toggleMark()
        app.beginPattern(marks: false)
        app.updatePattern("*.js")
        await panel.marksCounted()
        #expect(panel.markedCount == 0)
        app.cancelPattern()
        #expect(panel.markedCount == 1)
    }

    @Test func patternStaysOnThePanelItOpenedOn() async throws {
        let temp = try TempFolder()
        try temp.file("a.js")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        app.panels[1].refresh()
        await app.panels[1].loaded()
        panel.setCursor(1)
        app.beginPattern(marks: true)
        app.switchPanel()
        app.applyPattern()
        #expect(panel.markedCount == 1)
        #expect(app.panels[1].markedCount == 0)
    }

    @Test func leavingAFolderClosesItsPattern() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        try temp.file("a.js")
        try temp.file("sub/b.js")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        app.beginPattern(marks: true)
        app.updatePattern("*.js")
        panel.navigate(to: sub)
        await panel.loaded()
        #expect(app.patternBar == nil)
        #expect(panel.markedCount == 0)
        #expect(!panel.isMarked(panel.rows[1]))
    }

    @Test func goToClosesAPatternAndReopeningStartsClean() async throws {
        let temp = try TempFolder()
        try temp.file("a.js")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        panel.setCursor(1)
        app.beginPattern(marks: true)
        let first = app.patternBar?.id
        app.beginPattern(marks: false)
        #expect(app.patternBar?.id != first)
        app.beginGoTo()
        await panel.marksCounted()
        #expect(app.patternBar == nil)
        #expect(app.isGoingToPath)
        #expect(panel.markedCount == 0)
    }

    @Test func countsClearAsSoonAsAFolderIsLeft() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        try temp.file("a")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.markAll()
        panel.navigate(to: sub)
        #expect(panel.markedCount == 0)
        await panel.loaded()
    }

    @Test func markAllMeasuresFoldersAndReportsProgress() async throws {
        let temp = try TempFolder()
        try temp.folder("one")
        try temp.file("one/a", bytes: 10)
        try temp.folder("two")
        try temp.file("two/b", bytes: 20)
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.markAll()
        #expect(panel.isMeasuring)
        for _ in 0..<100 where panel.isMeasuring {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.markedSize == 30)
    }

    @Test func returningToATabFinishesItsMeasuring() async throws {
        let temp = try TempFolder()
        try temp.folder("one")
        try temp.file("one/a", bytes: 10)
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.markAll()
        panel.newTab()
        await panel.loaded()
        panel.nextTab(by: 1)
        await panel.loaded()
        for _ in 0..<100 where panel.isMeasuring {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.markedSize == 10)
    }

    @Test func packagesAreMeasured() async throws {
        let temp = try TempFolder()
        try temp.folder("Tool.app/Contents")
        try temp.file("Tool.app/Contents/binary", bytes: 64)
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.setCursor(1)
        panel.toggleMark()
        for _ in 0..<100 where panel.rows[1].size == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.markedSize == 64)
    }

    @Test func spaceExtendsASearchOnlyWhenANameContinues() async throws {
        let temp = try TempFolder()
        try temp.file("docs authoring")
        try temp.file("notes")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.search(typing: "docs")
        panel.markOrExtendSearch()
        #expect(panel.query == "docs ")
        #expect(panel.markedCount == 0)
        panel.endSearch()
        panel.search(typing: "notes")
        panel.markOrExtendSearch()
        #expect(panel.query.isEmpty)
        #expect(panel.markedCount == 1)
    }

    @Test func marksDropWithDeletedFiles() async throws {
        let temp = try TempFolder()
        let a = try temp.file("a")
        try temp.file("b")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.markAll()
        try FileManager.default.removeItem(at: a)
        panel.refresh()
        await panel.loaded()
        #expect(panel.markedCount == 1)
        #expect(panel.tab.marked.count == 1)
    }

    @Test func hidingFilesUnmarksThem() async throws {
        let temp = try TempFolder()
        try temp.file(".hidden")
        try temp.file("shown")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        app.toggleHidden()
        panel.markAll()
        #expect(panel.markedCount == 2)
        app.toggleHidden()
        #expect(panel.markedCount == 1)
        #expect(panel.tab.marked.count == 1)
    }

    @Test func tabsKeepMarksAndFoldersDont() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        try temp.file("a")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.markAll()
        panel.newTab()
        await panel.loaded()
        #expect(panel.markedCount == 0)
        panel.nextTab(by: 1)
        await panel.loaded()
        #expect(panel.markedCount == 2)
        panel.navigate(to: sub)
        await panel.loaded()
        panel.goBack()
        await panel.loaded()
        #expect(panel.markedCount == 0)
    }

    @Test func quickSearchFindsAndReportsNoMatch() async throws {
        let temp = try TempFolder()
        try temp.file("alpha.txt")
        try temp.file("beta.txt")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.search(typing: "B")
        #expect(panel.cursorEntry?.name == "beta")
        panel.search(typing: "zz")
        #expect(panel.queryFailed)
        #expect(panel.cursorEntry?.name == "beta")
        #expect(panel.eraseSearch())
        #expect(panel.eraseSearch())
        #expect(!panel.queryFailed)
        #expect(panel.eraseSearch())
        #expect(!panel.eraseSearch())
    }

    @Test func movingTheCursorEndsASearch() async throws {
        let temp = try TempFolder()
        try temp.file("alpha")
        try temp.file("beta")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.search(typing: "beta")
        panel.moveCursor(by: -1)
        #expect(panel.query.isEmpty)
    }

    @Test func folderSizesAddUpWithoutFollowingLinks() async throws {
        let temp = try TempFolder()
        let outside = try temp.folder("outside")
        try temp.file("outside/big", bytes: 1000)
        let sub = try temp.folder("sub")
        try temp.file("sub/one", bytes: 10)
        try temp.folder("sub/deep")
        try temp.file("sub/deep/two", bytes: 20)
        try FileManager.default.createSymbolicLink(at: sub.appending(path: "link"), withDestinationURL: outside)
        #expect(await LocalSource().folderSize(sub) == 30 + linkSize(sub))
    }

    private func linkSize(_ folder: URL) -> Int64 {
        let link = folder.appending(path: "link")
        let size = (try? FileManager.default.attributesOfItem(atPath: link.path))?[.size] as? Int64
        return size ?? 0
    }

    @Test func markingAFolderMeasuresItAndKeepsTheSize() async throws {
        let temp = try TempFolder()
        try temp.folder("sub")
        try temp.file("sub/one", bytes: 12)
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        panel.setCursor(1)
        panel.toggleMark()
        for _ in 0..<100 where panel.rows[1].size == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(panel.rows[1].size == 12)
        #expect(panel.markedSize == 12)
        panel.refresh()
        await panel.loaded()
        #expect(panel.rows[1].size == 12)
    }

    @Test func sessionRestoresTabsSortAndCursor() async throws {
        let temp = try TempFolder()
        let sub = try temp.folder("sub")
        try temp.file("sub/a")
        try temp.file("sub/b")
        var workspace: Workspace?
        let panel = await panel(temp, in: &workspace)
        let app = try #require(workspace)
        panel.newTab()
        await panel.loaded()
        panel.navigate(to: sub)
        await panel.loaded()
        panel.sort(by: .size)
        await panel.loaded()
        panel.setCursor(2)
        let cursorName = panel.cursorEntry?.name
        app.switchPanel()
        let data = try JSONEncoder().encode(app.session)
        let session = try JSONDecoder().decode(Session.self, from: data)
        let restored = Workspace(session: session, fallback: temp.url)
        #expect(restored.activeIndex == 1)
        let again = restored.panels[0]
        #expect(again.tabs.count == 2)
        #expect(again.tabIndex == 1)
        #expect(again.tab.sort.key == .size)
        restored.start()
        await again.loaded()
        #expect(again.location.lastPathComponent == "sub")
        #expect(again.cursorEntry?.name == cursorName)
    }

    @Test func missingFoldersRestoreToTheirParent() async throws {
        let temp = try TempFolder()
        var tab = TabState(location: temp.url.appending(path: "gone/deeper"))
        tab.savedCursor = nil
        let session = Session(panels: [PanelSession(tabs: [TabSession(tab)], tabIndex: 9)], activeIndex: 7)
        let restored = Workspace(session: session, fallback: temp.url)
        #expect(restored.panels[0].tabIndex == 0)
        #expect(restored.panels[0].location.path.hasSuffix(temp.url.lastPathComponent))
        #expect(restored.activeIndex == 0)
        #expect(restored.panels[1].location.path == temp.url.path)
    }
}
