import Foundation
import Testing
@testable import CommanderCore

private func file(_ name: String, modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> FileEntry {
    FileEntry(url: URL(filePath: "/folder/\(name)"), fileName: name, size: 1, modified: modified, isDirectory: false)
}

private func names(_ files: [String], _ change: (inout RenameOptions) -> Void, taken: Set<String> = []) -> [RenameRow] {
    var options = RenameOptions()
    options.name = "[N]"
    change(&options)
    return RenamePlan.rows(files.map { file($0) }, options, taken: taken)
}

@Suite struct RenamePlanTests {
    @Test func tokensFillIn() {
        #expect(names(["report.txt"], { $0.name = "x-[N]" })[0].fileName == "x-report.txt")
        #expect(names(["report.txt"], { $0.name = "[N1-3]" })[0].fileName == "rep.txt")
        #expect(names(["report.txt"], { $0.name = "[N3]" })[0].fileName == "p.txt")
        #expect(names(["report.txt"], { $0.ext = "bak" })[0].fileName == "report.bak")
        #expect(names(["report.txt"], { $0.name = "[E]-[N]" })[0].fileName == "txt-report.txt")
    }

    @Test func aRangePastTheEndStopsAtTheEnd() {
        #expect(names(["abc"], { $0.name = "[N2-99]" })[0].fileName == "bc")
        #expect(names(["abc"], { $0.name = "x[N9-12]" })[0].fileName == "x")
    }

    @Test func unknownBracketsAreLiteral() {
        #expect(names(["a"], { $0.name = "[X]-[N]" })[0].fileName == "[X]-a")
    }

    @Test func aNameKeepsItsDoubleExtension() {
        let row = names(["logs.tar.gz"], { $0.name = "[N]" })[0]
        #expect(row.ext == "tar.gz")
        #expect(!row.isChanged)
    }

    @Test func removingTheExtensionDropsTheDot() {
        #expect(names(["a.txt"], { $0.ext = "" })[0].fileName == "a")
    }

    @Test func theCounterStartsStepsAndPads() {
        let rows = names(["a", "b", "c"], { $0.name = "f[C]"; $0.counterStart = 8; $0.counterStep = 2; $0.counterDigits = 3 })
        #expect(rows.map(\.fileName) == ["f008", "f010", "f012"])
    }

    @Test func aCounterWiderThanItsDigitsIsntCut() {
        #expect(names(["a"], { $0.name = "[C]"; $0.counterStart = 1234; $0.counterDigits = 2 })[0].fileName == "1234")
    }

    @Test func aNegativeCounterKeepsItsSign() {
        #expect(names(["a"], { $0.name = "[C]"; $0.counterStart = -3 })[0].fileName == "-03")
    }

    @Test func theDateIsLocal() throws {
        var calendar = Calendar.current
        calendar.timeZone = .current
        for hour in [0, 23] {
            let moment = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: 30)))
            var options = RenameOptions()
            options.name = "[YMD]"
            let row = RenamePlan.rows([file("a", modified: moment)], options, taken: [])[0]
            #expect(row.fileName == "20261028")
        }
    }

    @Test func aPlainReplacementIsLiteral() {
        #expect(names(["a.b"], { $0.find = "a"; $0.replacement = "$&b" })[0].name == "$&b")
        #expect(names(["a.c"], { $0.find = "."; $0.replacement = "x" })[0].name == "a")
    }

    @Test func aRegexCanUseGroups() {
        #expect(names(["IMG_2024"], { $0.find = "IMG_(\\d+)"; $0.replacement = "photo-$1"; $0.usesRegex = true })[0].fileName == "photo-2024")
    }

    @Test func aBadRegexIsAProblemNotACrash() {
        #expect(names(["a"], { $0.find = "("; $0.usesRegex = true })[0].problem == "The search pattern isn't valid.")
    }

    @Test func aRegexReferenceToAMissingGroupIsntACrash() {
        _ = names(["abc"], { $0.find = "b"; $0.replacement = "$9"; $0.usesRegex = true })
    }

    @Test func caseChangesTheName() {
        #expect(names(["Some File.TXT"], { $0.caseChange = .lower })[0].fileName == "some file.TXT")
        #expect(names(["Some File.txt"], { $0.caseChange = .upper })[0].fileName == "SOME FILE.txt")
        #expect(names(["some-NASA file2b.txt"], { $0.caseChange = .title })[0].fileName == "Some-NASA File2b.txt")
    }

    @Test func invalidNamesAreCaught() {
        #expect(names(["a"], { $0.name = "" })[0].problem == "A name is empty.")
        #expect(names(["a"], { $0.name = "x/y" })[0].problem != nil)
        #expect(names(["a"], { $0.name = "x:y" })[0].problem != nil)
        #expect(names(["a"], { $0.name = ".." })[0].problem != nil)
        #expect(names(["a"], { $0.name = String(repeating: "x", count: 256) })[0].problem != nil)
    }

    @Test func collisionsInsideTheSetAreCaught() {
        let rows = names(["a", "b", "c"], { $0.name = "same" })
        #expect(rows.allSatisfy { $0.problem == "Two files would get the same name. Add [C] to number them." })
    }

    @Test func collisionsIgnoreCaseAndUnicodeForm() {
        let rows = names(["caf\u{E9}", "x"], { $0.find = "x"; $0.replacement = "CAFE\u{301}" })
        #expect(rows[0].problem != nil)
        #expect(rows[1].problem != nil)
    }

    @Test func aBystanderNameIsCaught() {
        #expect(names(["a"], { $0.name = "b" }, taken: ["b"])[0].problem == "That name is already in this folder.")
    }

    @Test func aSwapIsFine() {
        var options = RenameOptions()
        options.name = "[C]"
        let chain = RenamePlan.rows([file("02"), file("01")], options, taken: [])
        #expect(chain.map(\.fileName) == ["01", "02"])
        #expect(chain.allSatisfy { $0.problem == nil })
    }

    @Test func anUnchangedNameIsntJudged() {
        let rows = names(["10:30 notes.txt", "old.txt"], { $0.find = "old"; $0.replacement = "new" })
        #expect(rows[0].problem == nil)
        #expect(rows[1].problem == nil)
        #expect(rows[1].fileName == "new.txt")
    }

    @Test func aChangedNameStillIs() {
        #expect(names(["10:30 notes.txt"], { $0.name = "[N]-x" })[0].problem != nil)
    }

    @Test func aCaseSensitiveVolumeKeepsCaseDifferentNamesApart() {
        var options = RenameOptions()
        options.name = "[N]"
        options.find = "b"
        options.replacement = "a"
        let bystander = RenamePlan.rows([file("b")], options, taken: ["A"], caseSensitive: true)
        #expect(bystander[0].problem == nil)
        let ordinary = RenamePlan.rows([file("b")], options, taken: ["a"], caseSensitive: false)
        #expect(ordinary[0].problem != nil)
    }

    @Test func caseOnlyChangesAreFine() {
        let row = names(["readme.md"], { $0.name = "README" })[0]
        #expect(row.isChanged)
        #expect(row.problem == nil)
    }

    @Test func tenThousandRowsPlanQuickly() {
        let files = (0..<10_000).map { file("file\($0).txt") }
        var options = RenameOptions()
        options.find = "file"
        options.replacement = "doc"
        let elapsed = ContinuousClock().measure { _ = RenamePlan.rows(files, options, taken: []) }
        #expect(elapsed < .milliseconds(500))
    }
}

@Suite struct RenameEngineTests {
    private func steps(_ temp: TempFolder, _ pairs: [(String, String)]) -> [FileRename] {
        pairs.map { FileRename(from: temp.url.appending(path: $0.0), to: temp.url.appending(path: $0.1)) }
    }

    private func contents(_ temp: TempFolder) throws -> [String: String] {
        var found: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: temp.url.path) {
            found[name] = try String(contentsOf: temp.url.appending(path: name), encoding: .utf8)
        }
        return found
    }

    private func write(_ text: String, _ name: String, in temp: TempFolder) throws {
        try Data(text.utf8).write(to: temp.url.appending(path: name))
    }

    @Test func aSwapWorks() throws {
        let temp = try TempFolder()
        try write("one", "a", in: temp)
        try write("two", "b", in: temp)
        let result = RenameEngine.run(steps(temp, [("a", "b"), ("b", "a")]))
        #expect(result.done.count == 2)
        #expect(try contents(temp) == ["a": "two", "b": "one"])
    }

    @Test func aChainWorksInEitherOrder() throws {
        let temp = try TempFolder()
        try write("one", "1", in: temp)
        try write("two", "2", in: temp)
        _ = RenameEngine.run(steps(temp, [("1", "2"), ("2", "3")]))
        #expect(try contents(temp) == ["2": "one", "3": "two"])
    }

    @Test func aTargetThatAppearedLaterIsNotOverwrittenAndAllIsPutBack() throws {
        let temp = try TempFolder()
        try write("one", "a", in: temp)
        try write("two", "b", in: temp)
        try write("keep me", "d", in: temp)
        let result = RenameEngine.run(steps(temp, [("a", "c"), ("b", "d")]))
        #expect(result.done.isEmpty)
        #expect(result.failure?.name == "d")
        #expect(result.stranded.isEmpty)
        #expect(try contents(temp) == ["a": "one", "b": "two", "d": "keep me"])
    }

    @Test func aMissingSourceFailsAndPutsTheRestBack() throws {
        let temp = try TempFolder()
        try write("one", "a", in: temp)
        let result = RenameEngine.run(steps(temp, [("a", "x"), ("gone", "y")]))
        #expect(result.failure?.name == "gone")
        #expect(try contents(temp) == ["a": "one"])
    }

    @Test func stoppingPutsEverythingBack() throws {
        let temp = try TempFolder()
        try write("one", "a", in: temp)
        let control = JobControl()
        control.cancel()
        let result = RenameEngine.run(steps(temp, [("a", "x")]), control: control)
        #expect(result.wasStopped)
        #expect(result.done.isEmpty)
        #expect(try contents(temp) == ["a": "one"])
    }

    @Test(arguments: ["APFS", "HFS+", "Case-sensitive APFS", "MS-DOS"])
    func worksOnEveryVolumeType(format: String) throws {
        let image = try DiskImage(format: format)
        let first = image.mount.appending(path: "FIRST.TXT")
        let second = image.mount.appending(path: "SECOND.TXT")
        try Data("1".utf8).write(to: first)
        try Data("2".utf8).write(to: second)
        let result = RenameEngine.run([FileRename(from: first, to: second), FileRename(from: second, to: first)])
        #expect(result.done.count == 2)
        #expect(try String(contentsOf: first, encoding: .utf8) == "2")
        #expect(try String(contentsOf: second, encoding: .utf8) == "1")
    }

    @Test func aCaseOnlyRenameWorksOnAnOrdinaryVolume() throws {
        let image = try DiskImage(format: "APFS")
        let lower = image.mount.appending(path: "readme.md")
        try Data("x".utf8).write(to: lower)
        let result = RenameEngine.run([FileRename(from: lower, to: image.mount.appending(path: "README.md"))])
        #expect(result.done.count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: image.mount.path).contains("README.md"))
    }
}

@MainActor
@Suite struct RenameFlowTests {
    /// The manager only groups undo steps by run-loop pass in an app, so tests group by hand.
    private func setup(_ temp: TempFolder) async throws -> (Workspace, Panel, UndoManager) {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        let undo = UndoManager()
        undo.groupsByEvent = false
        app.undoManager = undo
        return (app, app.panels[0], undo)
    }

    private func load(_ panel: Panel) async {
        panel.refresh()
        await panel.loaded()
    }

    private func names(_ temp: TempFolder) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temp.url.appending(path: "a").path).sorted()
    }

    @Test func opensOnTheMarkedFilesAndLeavesOutFolders() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.folder("a/tree")
        try temp.file("a/one")
        try temp.file("a/two")
        await load(left)
        left.markAll()
        app.beginRename()
        #expect(app.renameSession?.files.map(\.fileName) == ["one", "two"])
        #expect(app.isTyping)
        app.cancelRename()
        #expect(app.renameSession == nil)
        #expect(try names(temp) == ["one", "tree", "two"])
    }

    @Test func nothingToRenameSaysSo() async throws {
        let temp = try TempFolder()
        let (app, _, _) = try await setup(temp)
        app.beginRename()
        #expect(app.renameSession == nil)
        #expect(app.message == "Mark the files to rename first.")
    }

    @Test func aHiddenFileHoldsItsNameEvenWhenItsRowDoesnt() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/.secret")
        await load(left)
        left.setCursor(1)
        app.beginRename()
        let session = try #require(app.renameSession)
        session.options.name = ".secret"
        session.options.ext = ""
        #expect(session.rows[0].problem == "That name is already in this folder.")
        #expect(!session.canRun)
        app.cancelRename()
    }

    @Test func problemsHoldBackTheRun() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/two")
        await load(left)
        left.markAll()
        app.beginRename()
        app.renameSession?.options.name = "same"
        app.runRename()
        #expect(app.renameSession != nil)
        #expect(try names(temp) == ["one", "two"])
        app.cancelRename()
    }

    @Test func nothingChangingHoldsBackTheRun() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        await load(left)
        left.setCursor(1)
        app.beginRename()
        app.renameSession?.options.name = "[N]"
        #expect(app.renameSession?.canRun == false)
        app.cancelRename()
    }

    @Test func aRenameRunsThenUndoesAndRedoesInOneStep() async throws {
        let temp = try TempFolder()
        let (app, left, undo) = try await setup(temp)
        for name in ["a1", "a2", "a3"] { try temp.file("a/\(name)") }
        await load(left)
        left.markAll()
        app.beginRename()
        app.renameSession?.options.name = "file[C]"
        undo.beginUndoGrouping()
        app.runRename()
        await app.jobs.finished()
        undo.endUndoGrouping()
        #expect(try names(temp) == ["file01", "file02", "file03"])
        #expect(app.message == "Renamed 3 items. Press ⌘Z to undo.")
        await left.loaded()
        #expect(left.markedCount == 0)

        undo.undo()
        await app.jobs.finished()
        #expect(try names(temp) == ["a1", "a2", "a3"])
        #expect(app.message == "Renamed 3 items.")
        undo.redo()
        await app.jobs.finished()
        #expect(try names(temp) == ["file01", "file02", "file03"])
        undo.undo()
        await app.jobs.finished()
        #expect(try names(temp) == ["a1", "a2", "a3"])
    }

    @Test func undoWaitsForARunningJob() async throws {
        let temp = try TempFolder()
        let (app, left, undo) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/big", bytes: 2_000_000)
        await load(left)
        left.setCursor(2)
        app.beginRename()
        app.renameSession?.options.name = "x"
        undo.beginUndoGrouping()
        app.runRename()
        await app.jobs.finished()
        undo.endUndoGrouping()
        await left.loaded()
        left.markAll()
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        undo.undo()
        #expect(app.jobs.waiting.count == 1 || app.jobs.current?.kind == .rename)
        await app.jobs.finished()
        #expect(try names(temp).contains("one"))
    }

    @Test func aFailedRunKeepsTheMarks() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/two")
        await load(left)
        left.markAll()
        app.beginRename()
        app.renameSession?.options.name = "x[N]"
        try temp.file("a/xtwo")
        app.runRename()
        await app.jobs.finished()
        await left.loaded()
        #expect(left.markedCount == 2)
    }

    @Test func aPackageIsRenamedLikeAFile() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.folder("a/Thing.app")
        try temp.folder("a/tree")
        await load(left)
        left.markAll()
        app.beginRename()
        #expect(app.renameSession?.files.map(\.fileName) == ["Thing.app"])
        app.cancelRename()
    }

    @Test func itWontOpenOverAnEditOrAPatternBar() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        await load(left)
        left.setCursor(1)
        left.beginRename()
        app.beginRename()
        #expect(app.renameSession == nil)
        left.cancelEdit()
        app.beginPattern(marks: true)
        app.beginRename()
        #expect(app.renameSession == nil)
        app.cancelPattern()
        app.beginRename()
        #expect(app.renameSession != nil)
        app.cancelRename()
    }

    @Test func aCaseSensitiveVolumeIsDetected() async throws {
        let image = try DiskImage(format: "Case-sensitive APFS")
        let temp = try TempFolder()
        let app = Workspace(left: image.mount, right: try temp.folder("b"))
        let left = app.panels[0]
        try Data().write(to: image.mount.appending(path: "A"))
        try Data().write(to: image.mount.appending(path: "b"))
        await load(left)
        left.setCursor(left.rows.firstIndex { $0.name == "b" } ?? 0)
        app.beginRename()
        let session = try #require(app.renameSession)
        session.options.name = "a"
        session.options.ext = ""
        #expect(session.canRun)
        app.runRename()
        await app.jobs.finished()
        let found = try FileManager.default.contentsOfDirectory(atPath: image.mount.path)
        #expect(found.contains("A"))
        #expect(found.contains("a"))
    }

    @Test func aFileLeftUnchangedIsNotTouched() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/keep")
        try temp.file("a/old")
        await load(left)
        left.markAll()
        app.beginRename()
        let session = try #require(app.renameSession)
        session.options.name = "[N]"
        session.options.find = "old"
        session.options.replacement = "new"
        #expect(session.preview.items.map(\.source.fileName) == ["old"])
        app.runRename()
        await app.jobs.finished()
        #expect(try names(temp) == ["keep", "new"])
    }

    @Test func aFailedRunIsReportedAndChangesNothing() async throws {
        let temp = try TempFolder()
        let (app, left, undo) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/two")
        await load(left)
        left.markAll()
        app.beginRename()
        app.renameSession?.options.name = "x[N]"
        try temp.file("a/xtwo")
        app.runRename()
        await app.jobs.finished()
        #expect(try names(temp) == ["one", "two", "xtwo"])
        #expect(app.report?.summary.hasPrefix("Nothing was renamed.") == true)
        #expect(!undo.canUndo)
    }

    @Test func theCursorFollowsItsFile() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/two")
        await load(left)
        left.setCursor(1)
        app.beginRename()
        app.renameSession?.options.name = "z"
        app.runRename()
        await app.jobs.finished()
        await left.loaded()
        #expect(left.cursorEntry?.name == "z")
    }

    @Test func theCursorFollowsItsFileThroughUndo() async throws {
        let temp = try TempFolder()
        let (app, left, undo) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("a/two")
        await load(left)
        left.setCursor(1)
        app.beginRename()
        app.renameSession?.options.name = "z"
        undo.beginUndoGrouping()
        app.runRename()
        await app.jobs.finished()
        undo.endUndoGrouping()
        await left.loaded()
        undo.undo()
        await app.jobs.finished()
        await left.loaded()
        #expect(left.cursorEntry?.name == "one")
    }

    @Test func leavingTheFolderClosesTheScreen() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        await load(left)
        left.setCursor(1)
        app.beginRename()
        left.navigate(to: temp.url.appending(path: "b"))
        #expect(app.renameSession == nil)
    }

    @Test func aThousandFilesPreviewLive() async throws {
        let temp = try TempFolder()
        let (app, left, undo) = try await setup(temp)
        for index in 0..<1_000 { try temp.file("a/file\(index)") }
        await load(left)
        left.markAll()
        app.beginRename()
        let session = try #require(app.renameSession)
        let elapsed = ContinuousClock().measure { session.options.name = "doc[C]" }
        #expect(elapsed < .milliseconds(50))
        session.options.counterDigits = 4
        undo.beginUndoGrouping()
        app.runRename()
        await app.jobs.finished()
        undo.endUndoGrouping()
        #expect(try names(temp).first == "doc0001")
        undo.undo()
        await app.jobs.finished()
        #expect(try names(temp).allSatisfy { $0.hasPrefix("file") })
    }
}
