import Foundation
import Testing
@testable import CommanderCore

@MainActor
@Suite struct MovingTabsTests {
    private func setup(_ temp: TempFolder) async throws -> Workspace {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        return app
    }

    private func names(_ panel: Panel) -> [String] {
        panel.tabs.map(\.title)
    }

    private func settle(_ app: Workspace) async {
        for panel in app.panels { await panel.loaded() }
    }

    /// Opens tabs on three folders in the left panel.
    private func threeTabs(_ app: Workspace, _ temp: TempFolder) async throws {
        for name in ["c", "d"] {
            app.panels[0].newTab()
            app.panels[0].navigate(to: try temp.folder(name))
            await app.panels[0].loaded()
        }
    }

    @Test func aTabReordersWithoutChangingWhatsShown() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try await threeTabs(app, temp)
        #expect(names(app.panels[0]) == ["a", "c", "d"])
        let first = app.panels[0].tabs[0].id
        app.moveTab(first, toPanel: 0, before: 3)
        #expect(names(app.panels[0]) == ["c", "d", "a"])
        #expect(app.panels[0].tab.title == "d")
        app.moveTab(first, toPanel: 0, before: 1)
        #expect(names(app.panels[0]) == ["c", "a", "d"])
    }

    @Test func theKeysMoveATabAlongItsStripAndStopAtTheEnds() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try await threeTabs(app, temp)
        app.shiftTab(by: 1)
        #expect(names(app.panels[0]) == ["a", "c", "d"])
        app.shiftTab(by: -1)
        #expect(names(app.panels[0]) == ["a", "d", "c"])
        #expect(app.panels[0].tab.title == "d")
        app.shiftTab(by: -1)
        app.shiftTab(by: -1)
        #expect(names(app.panels[0]) == ["d", "a", "c"])
    }

    @Test func aTabTakesEverythingToTheOtherPanel() async throws {
        let temp = try TempFolder()
        try temp.file("a/sub/deep.txt")
        try temp.file("a/one.txt")
        try temp.file("a/two.txt")
        let app = try await setup(temp)
        let left = app.panels[0]
        left.newTab()
        await left.loaded()
        left.navigate(to: temp.url.appending(path: "a/sub"))
        await left.loaded()
        left.goUp()
        await left.loaded()
        left.setCursor(2)
        left.toggleMark()
        left.sort(by: .size)
        await left.loaded()
        let (id, marked, back) = (left.tab.id, left.tab.marked, left.tab.back)
        #expect(!marked.isEmpty)
        app.moveTabToOtherPanel()
        await settle(app)
        let right = app.panels[1]
        #expect(app.activeIndex == 1)
        #expect(left.tabs.count == 1)
        #expect(right.tab.id == id)
        #expect(right.tab.marked == marked)
        #expect(right.tab.back == back)
        #expect(right.tab.sort.key == .size)
        #expect(right.markedCount == 1)
        #expect(right.rows.contains { $0.fileName == "one.txt" })
    }

    @Test func aTabGoesAndComesBackWhole() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.txt")
        let app = try await setup(temp)
        let left = app.panels[0]
        left.newTab()
        await left.loaded()
        left.markAll()
        let marked = left.tab.marked
        app.moveTabToOtherPanel()
        await settle(app)
        app.moveTabToOtherPanel()
        await settle(app)
        #expect(app.activeIndex == 0)
        #expect(left.tab.marked == marked)
        #expect(app.panels[1].tabs.count == 1)
    }

    @Test func thePanelsOnlyTabLeavesOneBehind() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.txt")
        let app = try await setup(temp)
        let left = app.panels[0]
        let id = left.tab.id
        app.moveTabToOtherPanel()
        await settle(app)
        #expect(left.tabs.count == 1)
        #expect(left.tab.id != id)
        #expect(left.tab.title == "a")
        #expect(left.rows.contains { $0.fileName == "one.txt" })
        #expect(app.panels[1].tabs.count == 2)
        #expect(app.panels[1].tab.id == id)
    }

    @Test func aTabNotShownMovesWithoutDisturbingTheOneThatIs() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try await threeTabs(app, temp)
        let left = app.panels[0]
        let hidden = left.tabs[0].id
        app.moveTab(hidden, toPanel: 1, before: 0)
        await settle(app)
        #expect(left.tab.title == "d")
        #expect(names(left) == ["c", "d"])
        #expect(names(app.panels[1]) == ["a", "b"])
        #expect(app.panels[1].tab.id == hidden)
    }

    @Test func aRunningSearchKeepsFillingItsTabInTheOtherPanel() async throws {
        let temp = try TempFolder()
        for index in 0..<30 { try temp.file("a/file\(index).md") }
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.name = "*.md"
        app.keepFind()
        app.moveTabToOtherPanel()
        #expect(session.panel === app.panels[1])
        await session.finished()
        await settle(app)
        #expect(app.panels[1].isResults)
        #expect(app.panels[1].rows.count == 30)
        #expect(app.panels[1].findStatus == nil)
    }

    @Test func nothingMovesWhileSomethingIsOpen() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.txt")
        let app = try await setup(temp)
        let left = app.panels[0]
        left.newTab()
        await left.loaded()
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(app.pending != nil)
        #expect(!app.canMoveTabs)
        app.moveTabToOtherPanel()
        #expect(left.tabs.count == 2)
        app.cancelOperation()
        app.beginPattern(marks: true)
        app.moveTabToOtherPanel()
        #expect(left.tabs.count == 2)
        app.cancelPattern()
        app.beginFind()
        app.moveTabToOtherPanel()
        #expect(left.tabs.count == 3)
        app.cancelFind()
        #expect(app.canMoveTabs)
    }

    @Test func anyTabCanBeClosedFromItsOwnButton() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try await threeTabs(app, temp)
        let left = app.panels[0]
        left.closeTab(id: left.tabs[0].id)
        #expect(names(left) == ["c", "d"])
        #expect(left.tab.title == "d")
        left.closeTab(id: left.tab.id)
        await left.loaded()
        #expect(names(left) == ["c"])
        left.closeTab(id: left.tab.id)
        #expect(names(left) == ["c"])
    }

    @Test func aMoveClosesTheViewerSoTheTabCanBeSeen() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.toggleViewer()
        app.moveTabToOtherPanel()
        #expect(app.viewer == nil)
    }

    @Test func aMoveHandsBackTheKeyboard() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let focus = app.focusTick
        app.moveTabToOtherPanel()
        #expect(app.focusTick > focus)
    }

    @Test func theyreInThePalette() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        for title in ["Move Tab to Other Panel", "Move Tab Left", "Move Tab Right"] {
            #expect(app.commands.first { $0.title == title }?.isEnabled == true)
        }
    }
}

@Suite struct NewestFirstQueueTests {
    @Test func theNewestGoesFirst() {
        var queue = NewestFirstQueue<Int>(limit: 10)
        queue.add("old", 1)
        queue.add("new", 2)
        #expect(queue.start()?.key == "new")
        #expect(queue.finish() == [2])
        #expect(queue.start()?.key == "old")
    }

    @Test func oneRunsAtATime() {
        var queue = NewestFirstQueue<Int>(limit: 10)
        queue.add("a", 1)
        queue.add("b", 2)
        #expect(queue.start() != nil)
        #expect(queue.start() == nil)
    }

    @Test func aKeyAskedForTwiceRunsOnceForBoth() {
        var queue = NewestFirstQueue<Int>(limit: 10)
        queue.add("a", 1)
        queue.add("b", 2)
        queue.add("a", 3)
        #expect(queue.start()?.key == "a")
        #expect(queue.finish() == [1, 3])
        #expect(queue.start()?.key == "b")
        #expect(queue.finish() == [2])
        #expect(queue.start() == nil)
    }

    @Test func askingForWhatsRunningJoinsIt() {
        var queue = NewestFirstQueue<Int>(limit: 10)
        queue.add("a", 1)
        _ = queue.start()
        queue.add("a", 2)
        #expect(queue.finish() == [1, 2])
        #expect(queue.start() == nil)
    }

    @Test func onlyTheOldestFallOff() {
        var queue = NewestFirstQueue<Int>(limit: 2)
        for (index, key) in ["a", "b", "c"].enumerated() { queue.add(key, index) }
        #expect(queue.start()?.key == "c")
        _ = queue.finish()
        #expect(queue.start()?.key == "b")
        _ = queue.finish()
        #expect(queue.start() == nil)
    }

    @Test func tallPanelsFitInTheQueueTheAppUses() {
        var queue = NewestFirstQueue<Int>(limit: 512)
        for row in 0..<240 { queue.add("row\(row)", row) }
        var loaded = 0
        while queue.start() != nil {
            loaded += queue.finish().count
        }
        #expect(loaded == 240)
    }
}

@Suite struct SavedTabTests {
    @Test func aResultsTabComesBackSortedByWhatAFolderShows() {
        var tab = TabState(location: URL(filePath: "/"))
        tab.sort = FileSort(key: .folder, ascending: false)
        let saved = TabSession(tab)
        #expect(saved.sort == FileSort(key: .ext, ascending: false))
    }
}

@MainActor
@Suite struct CompareAnyTabsTests {
    private func setup(_ temp: TempFolder) async throws -> Workspace {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        return app
    }

    private func addTab(_ panel: Panel, _ folder: URL) async {
        panel.newTab()
        panel.navigate(to: folder)
        await panel.loaded()
    }

    @Test func oneTabEachOpensAtOnce() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.beginCompare()
        #expect(app.compareChoice == nil)
        #expect(app.compareSession != nil)
    }

    @Test func moreTabsAskFirstStartingFromTheOnesShown() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        await addTab(app.panels[0], try temp.folder("c"))
        app.beginCompare()
        #expect(app.compareSession == nil)
        #expect(app.compareChoice == CompareChoice(first: app.panels[0].tab.id, second: app.panels[1].tab.id))
        #expect(app.isTyping)
        app.runCompareChoice()
        #expect(app.compareChoice == nil)
        #expect(app.compareSession?.left.lastPathComponent == "c")
        #expect(app.compareSession?.right.lastPathComponent == "b")
    }

    @Test func twoTabsInOnePanelCanBeCompared() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let left = app.panels[0]
        await addTab(left, try temp.folder("c"))
        app.beginCompare()
        app.chooseCompare(CompareChoice(first: left.tabs[1].id, second: left.tabs[0].id))
        app.runCompareChoice()
        #expect(app.compareSession?.left.lastPathComponent == "c")
        #expect(app.compareSession?.right.lastPathComponent == "a")
    }

    @Test func aSyncBetweenTwoTabsInOnePanelWorks() async throws {
        let temp = try TempFolder()
        let c = try temp.folder("c")
        let file = try temp.file("c/new.txt", bytes: 5)
        let app = try await setup(temp)
        let left = app.panels[0]
        await addTab(left, c)
        app.beginCompare()
        app.chooseCompare(CompareChoice(first: left.tabs[1].id, second: left.tabs[0].id))
        app.runCompareChoice()
        let session = try #require(app.compareSession)
        await session.finished()
        app.runSync()
        await app.jobs.finished()
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "a/new.txt").path))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func theSameFolderStaysInTheBarWithTheReason() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let left = app.panels[0]
        left.newTab()
        await left.loaded()
        app.beginCompare()
        app.chooseCompare(CompareChoice(first: left.tabs[0].id, second: left.tabs[1].id))
        app.runCompareChoice()
        #expect(app.compareSession == nil)
        #expect(app.compareChoice != nil)
        #expect(app.message == "Both show the same folder.")
    }

    @Test func oneFolderInsideTheOtherIsStillRefused() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let left = app.panels[0]
        await addTab(left, try temp.folder("a/inner"))
        app.beginCompare()
        app.chooseCompare(CompareChoice(first: left.tabs[0].id, second: left.tabs[1].id))
        app.runCompareChoice()
        #expect(app.compareSession == nil)
        #expect(app.message == "One folder is inside the other.")
    }

    @Test func resultsAndArchivesArentOffered() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.name = "*.md"
        await session.finished()
        app.keepFind()
        #expect(app.comparableTabs.map(\.title) == ["a", "b"])
        app.beginCompare()
        #expect(app.compareChoice == CompareChoice(first: app.panels[0].tabs[0].id, second: app.panels[1].tab.id))
    }

    @Test func theKeysStepThroughTheTabs() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let left = app.panels[0]
        await addTab(left, try temp.folder("c"))
        app.beginCompare()
        let start = try #require(app.compareChoice)
        app.stepCompare(first: true, by: 1)
        #expect(app.compareChoice?.first == app.panels[1].tab.id)
        app.stepCompare(first: true, by: 1)
        app.stepCompare(first: false, by: -1)
        #expect(app.compareChoice?.first == left.tabs[0].id)
        #expect(app.compareChoice?.second == start.first)
    }

    @Test func aHiddenTabClosingUnderTheChoiceEndsIt() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let left = app.panels[0]
        await addTab(left, try temp.folder("c"))
        app.beginCompare()
        app.chooseCompare(CompareChoice(first: left.tabs[0].id, second: app.panels[1].tab.id))
        left.closeTab(id: left.tabs[0].id)
        #expect(app.compareChoice == nil)
    }

    @Test func aHiddenTabTheChoiceDoesntUseCanClose() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let left = app.panels[0]
        await addTab(left, try temp.folder("c"))
        await addTab(left, try temp.folder("d"))
        app.beginCompare()
        left.closeTab(id: left.tabs[0].id)
        #expect(app.compareChoice != nil)
    }

    @Test func cancellingGivesBackTheKeyboard() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        await addTab(app.panels[0], try temp.folder("c"))
        app.beginCompare()
        let focus = app.focusTick
        app.cancelCompareChoice()
        #expect(app.compareChoice == nil)
        #expect(app.focusTick == focus + 1)
    }

    @Test func aTabClosingUnderTheChoiceEndsIt() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        await addTab(app.panels[0], try temp.folder("c"))
        app.beginCompare()
        app.panels[0].closeTab()
        #expect(app.compareChoice == nil)
    }
}
