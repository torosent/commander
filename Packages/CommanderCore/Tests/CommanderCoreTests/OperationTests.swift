import Darwin
import Foundation
import Testing
@testable import CommanderCore

@MainActor
@Suite struct OperationTests {
    /// Left panel on `a`, right on `b`.
    private func setup(_ temp: TempFolder) async throws -> (Workspace, Panel, Panel) {
        let left = try temp.folder("a")
        let right = try temp.folder("b")
        let app = Workspace(left: left, right: right)
        app.panels[0].refresh()
        app.panels[1].refresh()
        await app.panels[0].loaded()
        await app.panels[1].loaded()
        return (app, app.panels[0], app.panels[1])
    }

    private func reload(_ panels: Panel...) async {
        for panel in panels {
            panel.refresh()
            await panel.loaded()
        }
    }

    @Test func nothingHappensUntilRun() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one")
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(app.pending != nil)
        #expect(!FileNames.exists(temp.url.appending(path: "b/one")))
        #expect(right.rows.contains { $0.name == "one" })
        #expect(right.previewState(of: right.rows[1]) == .incoming)
        app.cancelOperation()
        #expect(!right.rows.contains { $0.name == "one" })
        await app.jobs.finished()
    }

    @Test func runningCopiesAndClearsMarks() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one", bytes: 10)
        try temp.file("a/two", bytes: 20)
        await reload(left)
        left.markAll()
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        await right.loaded()
        #expect(left.markedCount == 0)
        #expect(right.rows.count == 3)
        #expect(app.message == "Copied 2 items.")
    }

    @Test func ghostRowsLandInSortedOrder() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/m")
        try temp.file("b/a")
        try temp.file("b/z")
        await reload(left, right)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(right.rows.map(\.name) == ["..", "a", "m", "z"])
        app.cancelOperation()
    }

    @Test func aConflictIsShownAndScrolledTo() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let source = try temp.file("a/shared")
        try temp.file("b/shared")
        for index in 0..<50 { try temp.file("b/zz\(index)") }
        try FileManager.default.setAttributes([.modificationDate: Date.now.addingTimeInterval(100)], ofItemAtPath: source.path)
        await reload(left, right)
        left.setCursor(1)
        let before = right.scrollRequest
        app.begin(.copy)
        await app.planned()
        #expect(right.scrollRequest == before + 1)
        #expect(right.rows[right.scrollTarget].name == "shared")
        #expect(right.previewState(of: right.rows[right.scrollTarget]) == .replacing(.older))
        app.cancelOperation()
    }

    @Test func aNewerDestinationIsSkippedByDefault() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let source = try temp.file("a/shared", bytes: 1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: source.path)
        try Data(count: 7).write(to: temp.url.appending(path: "b/shared"))
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(app.pending?.choice == .skip)
        app.runOperation()
        await app.jobs.finished()
        #expect(try Data(contentsOf: temp.url.appending(path: "b/shared")).count == 7)
        #expect(app.message == "Nothing to do: every item was skipped.")
    }

    /// A conflict the preview has shown, ready to replace.
    private func plannedReplace(_ kind: OperationKind, _ temp: TempFolder) async throws -> Workspace {
        let (app, left, _) = try await setup(temp)
        try temp.file("a/shared", bytes: 3)
        let target = try temp.file("b/shared", bytes: 5)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000.5)], ofItemAtPath: target.path)
        await reload(left)
        left.setCursor(1)
        app.begin(kind)
        await app.planned()
        #expect(app.pending?.choice == .replace)
        return app
    }

    @Test(arguments: [OperationKind.copy, .move])
    func aFileSavedAfterThePreviewIsKept(kind: OperationKind) async throws {
        let temp = try TempFolder()
        let app = try await plannedReplace(kind, temp)
        try temp.file("b/shared", bytes: 9)
        app.runOperation()
        await app.jobs.finished()
        #expect(try Data(contentsOf: temp.url.appending(path: "b/shared")).count == 9)
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "a/shared").path))
        #expect(app.report?.failures.first?.reason == "It changed after the preview, so it was left alone.")
    }

    @Test func aFileLeftAloneSinceThePreviewIsReplaced() async throws {
        let temp = try TempFolder()
        let app = try await plannedReplace(.copy, temp)
        app.runOperation()
        await app.jobs.finished()
        #expect(try Data(contentsOf: temp.url.appending(path: "b/shared")).count == 3)
    }

    @Test func aFileGoneSinceThePreviewIsStillCopied() async throws {
        let temp = try TempFolder()
        let app = try await plannedReplace(.copy, temp)
        try FileManager.default.removeItem(at: temp.url.appending(path: "b/shared"))
        app.runOperation()
        await app.jobs.finished()
        #expect(try Data(contentsOf: temp.url.appending(path: "b/shared")).count == 3)
    }

    @Test func aLockedFileIsRefusedInThePreview() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let locked = try temp.file("a/locked")
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        defer { chflags(locked.path, 0) }
        await reload(left)
        left.setCursor(1)
        app.begin(.move)
        await app.planned()
        #expect(app.pending == nil)
        #expect(app.message == "locked or its folder is locked, so it can't be moved.")
    }

    @Test func keepBothPreviewsAndWritesTheFreeName() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/note.md", bytes: 1)
        try temp.file("b/note.md", bytes: 7)
        await reload(left, right)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        app.choose(.keepBoth)
        #expect(right.rows.map(\.fileName).contains("note 2.md"))
        app.runOperation()
        await app.jobs.finished()
        #expect(FileNames.exists(temp.url.appending(path: "b/note 2.md")))
        #expect(try Data(contentsOf: temp.url.appending(path: "b/note.md")).count == 7)
    }

    @Test func moveShowsLeavingRowsAndRemovesTheSource() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let file = try temp.file("a/one")
        await reload(left)
        left.setCursor(1)
        app.begin(.move)
        await app.planned()
        #expect(left.previewState(of: left.rows[1]) == .leaving)
        app.runOperation()
        await app.jobs.finished()
        #expect(!FileNames.exists(file))
        #expect(FileNames.exists(temp.url.appending(path: "b/one")))
    }

    @Test func trashMovesToTheTrashNotAway() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let file = try temp.file("a/commander-trash-test-\(UUID().uuidString)")
        await reload(left)
        left.setCursor(1)
        app.begin(.trash)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(!FileNames.exists(file))
        #expect(app.message == "Moved to Trash: 1 item.")
        let trash = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
        try? FileManager.default.removeItem(at: trash.appending(path: file.lastPathComponent))
    }

    @Test func deleteRemovesALinkNotItsTarget() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let real = try temp.file("b/real")
        let link = temp.url.appending(path: "a/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await reload(left)
        left.setCursor(1)
        app.begin(.delete)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(!FileNames.exists(link))
        #expect(FileNames.exists(real))
    }

    @Test func leavingAFolderCancelsThePreview() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let sub = try temp.folder("a/sub")
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        left.navigate(to: sub)
        await left.loaded()
        #expect(app.pending == nil)
        #expect(right.rows.count == 1)
    }

    @Test func aRefusalSaysWhy() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let inner = try temp.folder("a/inner")
        let right = app.panels[1]
        right.navigate(to: inner)
        await right.loaded()
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(app.pending == nil)
        #expect(app.message == OperationRefusal.folderIntoItself.message)
    }

    @Test func failuresStayUntilDismissed() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let file = try temp.file("a/locked", bytes: 4)
        await reload(left)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(app.report?.failures.count == 1)
        #expect(app.report?.summary.contains("1 failed: locked") == true)
        app.dismissReport()
        #expect(app.report == nil)
    }

    @Test func aLaterJobDoesntHideAnEarlierFailure() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let first = try temp.file("a/first", bytes: 4)
        let second = try temp.file("a/second", bytes: 4)
        await reload(left)
        for file in [first, second] {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        }
        defer {
            for file in [first, second] {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            }
        }
        for row in 1...2 {
            left.setCursor(row)
            app.begin(.copy)
            await app.planned()
            app.runOperation()
        }
        await app.jobs.finished()
        #expect(app.report?.summary.contains("first") == true)
        app.dismissReport()
        #expect(app.report?.summary.contains("second") == true)
        app.dismissReport()
        #expect(app.report == nil)
    }

    @Test func aPlanIsDroppedIfItsFolderChanged() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one")
        let other = try temp.folder("elsewhere")
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        right.navigate(to: other)
        await app.planned()
        #expect(app.pending == nil)
        #expect(right.previewKind == nil)
    }

    @Test func aSecondPlanWaitsForTheFirst() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one")
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        app.begin(.delete)
        await app.planned()
        #expect(app.pending?.preview.kind == .copy)
        app.cancelOperation()
        #expect(right.previewKind == nil)
    }

    @Test func aPreviewHoldsOffNewFoldersAndRenames() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one")
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        left.beginRename()
        left.beginNewFolder()
        right.beginNewFolder()
        #expect(left.edit == nil)
        #expect(right.edit == nil)
        app.cancelOperation()
    }

    @Test func leavingAFolderAbandonsARename() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let file = try temp.file("a/one")
        await reload(left)
        left.setCursor(1)
        left.beginRename()
        #expect(app.isTyping)
        left.navigate(to: temp.url.appending(path: "b"))
        await left.loaded()
        #expect(left.edit == nil)
        try left.commitEdit("two")
        #expect(FileNames.exists(file))
    }

    @Test func leavingAFolderDropsADraftFolder() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        left.beginNewFolder()
        left.navigate(to: temp.url.appending(path: "b"))
        await left.loaded()
        #expect(left.edit == nil)
        #expect(!left.rows.contains { $0.name == "untitled folder" })
    }

    @Test func progressCountsFoldersAndLeavesOutSkips() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/file", bytes: 100)
        try temp.folder("a/tree")
        try temp.file("a/tree/inner", bytes: 5_000)
        try temp.file("a/taken", bytes: 900)
        try temp.file("b/taken", bytes: 1)
        await reload(left, right)
        left.markAll()
        app.begin(.copy)
        await app.planned()
        app.choose(.skip)
        app.runOperation()
        let job = try #require(app.jobs.current)
        await app.jobs.finished()
        #expect(job.totalBytes == 5_100)
        #expect(job.fraction == 1)
    }

    @Test func progressOfADeleteGoesByItems() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one", bytes: 1_000)
        await reload(left)
        left.setCursor(1)
        app.begin(.delete)
        await app.planned()
        app.runOperation()
        let job = try #require(app.jobs.current)
        await app.jobs.finished()
        #expect(job.totalBytes == 0)
        #expect(job.fraction == 1)
    }

    @Test func stoppingAllDropsTheQueue() async throws {
        let temp = try TempFolder()
        let folder = try temp.folder("to")
        let entries = [try temp.file("one", bytes: 10), try temp.file("two", bytes: 10)].compactMap(LocalSource.entry)
        let queue = JobQueue()
        for entry in entries {
            queue.add(try OperationPreview.plan(.copy, sources: [entry], into: folder), choice: .skip)
        }
        queue.stopAll()
        await queue.finished()
        #expect(queue.waiting.isEmpty)
        #expect(!FileNames.exists(folder.appending(path: "two")))
    }

    @Test func aDropFromTheOtherPanelTreatsThatPanelAsTheSource() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("b/kept")
        await reload(left, right)
        left.setCursor(1)
        left.toggleMark()
        right.setCursor(1)
        right.toggleMark()
        app.activate(1)
        app.begin(.move, entries: left.selectionEntries, into: right.location)
        await app.planned()
        #expect(app.pending?.source === left)
        #expect(left.previewState(of: left.rows[1]) == .leaving)
        app.runOperation()
        await app.jobs.finished()
        #expect(right.markedCount == 1)
    }

    @Test func aPasteFromElsewhereHasNoSourcePanelAndLeavesMarksAlone() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/marked")
        try temp.file("away")
        await reload(left, right)
        left.setCursor(1)
        left.toggleMark()
        app.paste([temp.url.appending(path: "away")], move: false)
        await app.planned()
        #expect(app.pending != nil)
        #expect(app.pending?.source == nil)
        app.runOperation()
        await app.jobs.finished()
        #expect(left.markedCount == 1)
        #expect(FileNames.exists(temp.url.appending(path: "a/away")))
    }

    @Test func actingOnOneRowKeepsTheOtherMarks() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/two")
        await reload(left)
        left.setCursor(1)
        left.toggleMark()
        app.begin(.copy, entries: [left.rows[2]])
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(left.markedCount == 1)
    }

    @Test func ghostsLandInSortedOrderAmongTheRows() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        for name in ["e", "a", "c"] { try temp.file("a/\(name)") }
        for name in ["d", "b"] { try temp.file("b/\(name)") }
        await reload(left, right)
        left.markAll()
        app.begin(.copy)
        await app.planned()
        #expect(right.rows.dropFirst().map(\.name) == ["a", "b", "c", "d", "e"])
        app.cancelOperation()
        #expect(right.rows.dropFirst().map(\.name) == ["b", "d"])
    }

    @Test func theParentRowKeepsTheCursorOverAFileNamedLikeIt() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        let inner = try temp.folder("a/inner")
        try temp.file("a/inner/a")
        left.navigate(to: inner)
        await left.loaded()
        left.setCursor(0)
        left.refresh()
        await left.loaded()
        #expect(left.cursorIndex == 0)
    }

    @Test func cancellingANewFolderPutsTheCursorBack() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        try temp.folder("a/tree")
        try temp.file("a/one")
        await reload(left)
        left.setCursor(2)
        left.beginNewFolder()
        left.cancelEdit()
        #expect(left.cursorEntry?.name == "one")
    }

    @Test func aDestinationFromTheSameMomentIsNeitherOlderNorNewer() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for path in ["a/one", "b/one"] {
            let file = try temp.file(path)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        await reload(left, right)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(right.previewState(of: right.rows[1]) == .replacing(.same))
        app.cancelOperation()
    }

    @Test func aTransferClosesTheViewerSoItsPreviewShows() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        await reload(left)
        left.setCursor(1)
        app.toggleViewer()
        app.begin(.trash)
        await app.planned()
        #expect(app.viewer != nil)
        app.cancelOperation()
        app.begin(.copy)
        await app.planned()
        #expect(app.viewer == nil)
        app.cancelOperation()
    }

    @Test func jobsRunOneAtATimeInOrder() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one", bytes: 2_000_000)
        try temp.file("a/two", bytes: 2_000_000)
        await reload(left)
        left.setCursor(1)
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        left.setCursor(2)
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        #expect(app.jobs.current != nil)
        await app.jobs.finished()
        #expect(FileNames.exists(temp.url.appending(path: "b/one")))
        #expect(FileNames.exists(temp.url.appending(path: "b/two")))
    }

    @Test func stoppingReportsAndKeepsThePartsDone() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        for index in 0..<30 { try temp.file("a/file\(index)", bytes: 1_000) }
        await reload(left)
        left.markAll()
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        app.jobs.stopCurrent()
        await app.jobs.finished()
        #expect(app.report?.wasStopped == true)
    }

    @Test func newFolderCreatesAndSelectsIt() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        left.beginNewFolder()
        #expect(left.cursorEntry?.name == "untitled folder")
        _ = try left.commitEdit("reports")
        await left.loaded()
        #expect(FileNames.exists(temp.url.appending(path: "a/reports")))
        #expect(left.cursorEntry?.name == "reports")
        #expect(left.edit == nil)
    }

    @Test func cancellingANewFolderLeavesNothing() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        left.beginNewFolder()
        left.cancelEdit()
        #expect(left.rows.count == 1)
        #expect(!FileNames.exists(temp.url.appending(path: "a/untitled folder")))
    }

    @Test func newFolderReportsAClash() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        try temp.folder("a/taken")
        await reload(left)
        left.beginNewFolder()
        #expect(throws: EditFailure.self) { _ = try left.commitEdit("taken") }
        #expect(left.edit != nil)
        left.cancelEdit()
    }

    @Test func renameThenUndo() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        let file = try temp.file("a/old.txt")
        await reload(left)
        left.setCursor(1)
        left.beginRename()
        #expect(left.edit?.text == "old.txt")
        undo.beginUndoGrouping()
        try left.commitEdit("new.txt")
        undo.endUndoGrouping()
        await left.loaded()
        #expect(left.cursorEntry?.fileName == "new.txt")
        #expect(!FileNames.exists(file))
        #expect(undo.undoActionName == "Rename")
        undo.undo()
        await app.jobs.finished()
        await left.loaded()
        #expect(left.cursorEntry?.fileName == "old.txt")
        undo.redo()
        await app.jobs.finished()
        await left.loaded()
        #expect(left.cursorEntry?.fileName == "new.txt")
    }

    @Test func undoingARenameWaitsForTheJobUsingTheFile() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        try temp.file("a/old", bytes: 40_000_000)
        await reload(left)
        left.setCursor(1)
        left.beginRename()
        undo.beginUndoGrouping()
        try left.commitEdit("new")
        undo.endUndoGrouping()
        await left.loaded()
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        undo.undo()
        await app.jobs.finished()
        await reload(left, right)
        #expect(FileNames.exists(temp.url.appending(path: "a/old")))
        #expect(FileNames.exists(temp.url.appending(path: "b/new")))
        #expect(app.report == nil)
    }

    /// Files in `a`, planned as one move to a real second volume.
    private func looseMove(_ count: Int, _ temp: TempFolder, to image: DiskImage) throws -> OperationPreview {
        let files = try (0..<count).map { try temp.file("a/f\($0)") }
        return try OperationPreview.plan(.move, sources: files.compactMap(LocalSource.entry), into: image.mount)
    }

    @Test func aMoveOfLooseFilesSharesOneDiskSync() throws {
        let temp = try TempFolder()
        let image = try DiskImage(format: "APFS")
        let preview = try looseMove(100, temp, to: image)
        let control = JobControl()
        let report = JobQueue.perform(preview, .skip, control)
        #expect(report.succeeded == 100)
        #expect(control.snapshot.syncs == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.appending(path: "a").path).isEmpty)
    }

    @Test func aBigMoveSyncsOnceABatch() throws {
        let temp = try TempFolder()
        let image = try DiskImage(format: "APFS")
        let preview = try looseMove(CopyEngine.settleBatch + 1, temp, to: image)
        let control = JobControl()
        _ = JobQueue.perform(preview, .skip, control)
        #expect(control.snapshot.syncs == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.appending(path: "a").path).isEmpty)
    }

    @Test func stoppingAMoveLeavesEachFileOnOneSide() async throws {
        let temp = try TempFolder()
        let image = try DiskImage(format: "APFS")
        let preview = try looseMove(400, temp, to: image)
        let control = JobControl()
        let job = Task.detached { JobQueue.perform(preview, .skip, control) }
        // Its own thread, because everything else in a test run can stall for longer than this job takes.
        Thread.detachNewThread {
            while control.snapshot.items < 5 {}
            control.cancel()
        }
        let report = await job.value
        #expect(report.wasStopped)
        for index in 0..<400 {
            let isThere = FileNames.exists(temp.url.appending(path: "a/f\(index)"))
            #expect(isThere != FileNames.exists(image.mount.appending(path: "f\(index)")))
        }
    }

    @Test func aFailedFileDoesntStopTheRestOfAMove() async throws {
        let temp = try TempFolder()
        let left = try temp.folder("a")
        let image = try DiskImage(format: "APFS")
        let app = Workspace(left: left, right: image.mount)
        await reload(app.panels[0], app.panels[1])
        for name in ["one", "two", "three"] { try temp.file("a/\(name)") }
        await reload(app.panels[0])
        app.panels[0].invertMarks()
        app.begin(.move)
        await app.planned()
        // Locked after the preview, so the job has to find it.
        let locked = temp.url.appending(path: "a/two")
        chflags(locked.path, UInt32(UF_IMMUTABLE))
        defer { chflags(locked.path, 0) }
        app.runOperation()
        await app.jobs.finished()
        for name in ["one", "three"] {
            #expect(!FileNames.exists(left.appending(path: name)))
            #expect(FileNames.exists(image.mount.appending(path: name)))
        }
        #expect(FileNames.exists(locked))
        #expect(!FileNames.exists(image.mount.appending(path: "two")))
        #expect(app.report?.failures.map(\.name) == ["two"])
    }

    @Test func thePaletteWontCopyFromInsideAnArchive() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        var copied: [URL] = []
        app.desktop.copyFiles = { copied = $0 }
        let archive = temp.url.appending(path: "a/made.zip")
        let file = try temp.file("a/one")
        _ = try ArchiveWriter().compress([file], to: archive, format: .zip)
        await reload(left)
        app.copyFiles(left.selectionEntries, in: left)
        #expect(copied.isEmpty)
        left.navigate(to: archive)
        await left.loaded()
        left.setCursor(1)
        app.copyFiles(left.selectionEntries, in: left)
        #expect(copied.isEmpty)
        #expect(app.message == "Copy files out of an archive with F5.")
    }

    @Test func theRenameKeyRenamesAFolderInPlaceAndCanUndo() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        try temp.file("a/project/inside")
        await reload(left)
        left.setCursor(1)
        app.beginRename()
        #expect(app.renameSession == nil)
        #expect(left.edit?.text == "project")
        undo.beginUndoGrouping()
        try left.commitEdit("renamed")
        undo.endUndoGrouping()
        await left.loaded()
        #expect(left.cursorEntry?.fileName == "renamed")
        #expect(FileNames.exists(temp.url.appending(path: "a/renamed/inside")))
        undo.undo()
        await app.jobs.finished()
        await left.loaded()
        #expect(left.cursorEntry?.fileName == "project")
        #expect(FileNames.exists(temp.url.appending(path: "a/project/inside")))
    }

    @Test func theRenameKeyNeedsTheFolderUnderTheCursor() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.folder("a/one")
        try temp.folder("a/two")
        await reload(left)
        left.setCursor(1)
        left.toggleMark()
        left.setCursor(2)
        app.beginRename()
        #expect(left.edit == nil)
        #expect(app.message == "Mark the files to rename first.")
    }

    @Test func renameNeverReplacesAFile() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        try temp.file("a/one", bytes: 1)
        try temp.file("a/two", bytes: 2)
        await reload(left)
        left.setCursor(1)
        left.beginRename()
        #expect(throws: EditFailure.self) { _ = try left.commitEdit("two") }
        #expect(try Data(contentsOf: temp.url.appending(path: "a/two")).count == 2)
        left.cancelEdit()
    }

    @Test func caseOnlyRenameWorks() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        try temp.file("a/name")
        await reload(left)
        left.setCursor(1)
        left.beginRename()
        _ = try left.commitEdit("NAME")
        await left.loaded()
        #expect(left.cursorEntry?.fileName == "NAME")
    }

    @Test func pastingCopiesIntoTheActivePanel() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let file = try temp.file("b/shared", bytes: 3)
        await reload(left, right)
        app.paste([file], move: false)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(FileNames.exists(temp.url.appending(path: "a/shared")))
        #expect(FileNames.exists(file))
    }

    /// M3 exit target. Run with: COMMANDER_PERF=1 swift test --filter tenThousand
    @Test(.enabled(if: ProcessInfo.processInfo.environment["COMMANDER_PERF"] != nil))
    func tenThousandMixedFilesCopyByteIdentical() async throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        for folder in 0..<100 {
            try temp.folder("tree/f\(folder)")
            for index in 0..<100 {
                var bytes = Data(count: (index * 137) % 9_000)
                bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
                try bytes.write(to: tree.appending(path: "f\(folder)/file\(index)"))
            }
        }
        let image = try DiskImage(format: "APFS", megabytes: 300)
        let target = image.mount.appending(path: "tree", directoryHint: .isDirectory)
        let report = try CopyEngine().copy(tree, to: target, conflict: .skip)
        #expect(report.failures.isEmpty)
        var compared = 0
        for folder in 0..<100 {
            for index in 0..<100 {
                let name = "f\(folder)/file\(index)"
                let same = try Data(contentsOf: tree.appending(path: name)) == Data(contentsOf: target.appending(path: name))
                #expect(same)
                compared += 1
            }
        }
        #expect(compared == 10_000)
    }
}
