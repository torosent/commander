import Darwin
import Foundation
import Testing
@testable import CommanderCore

private final class Found: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [FileEntry] = []

    func add(_ batch: [FileEntry]) {
        lock.withLock { entries += batch }
    }

    var names: [String] { lock.withLock { entries.map(\.fileName).sorted() } }
    var paths: [String] { lock.withLock { entries.map(\.url.path).sorted() } }
}

private func find(
    _ root: URL, name: String = "", contains: String = "", hidden: Bool = false,
    spotlight: [URL] = [], control: JobControl = JobControl()
) -> (found: Found, outcome: FindOutcome) {
    let found = Found()
    let real = URL(filePath: FileNames.realPath(root) ?? root.path, directoryHint: .isDirectory)
    let finder = FileFinder(query: FindQuery(name: name, contains: contains), roots: [real], showHidden: hidden, control: control)
    finder.hits.offer(spotlight)
    let outcome = finder.run { found.add($0) }
    return (found, outcome)
}

@Suite struct FileFinderTests {
    @Test func aPlainNameMatchesInsideAnyName() throws {
        let temp = try TempFolder()
        try temp.file("Report.md")
        try temp.file("sub/old-REPORT.txt")
        try temp.file("other.md")
        #expect(find(temp.url, name: "report").found.names == ["Report.md", "old-REPORT.txt"])
    }

    @Test func aMaskMatchesTheWholeName() throws {
        let temp = try TempFolder()
        try temp.file("a.md")
        try temp.file("a.md.bak")
        try temp.file("b.txt")
        #expect(find(temp.url, name: "*.md, *.TXT").found.names == ["a.md", "b.txt"])
    }

    @Test func foldersMatchByNameAndAreStillSearched() throws {
        let temp = try TempFolder()
        try temp.file("docs/docs.md")
        #expect(find(temp.url, name: "docs").found.names == ["docs", "docs.md"])
    }

    @Test func contentIsFoundWhateverTheCase() throws {
        let temp = try TempFolder()
        try "the Quick fox".write(to: temp.url.appending(path: "yes.txt"), atomically: false, encoding: .utf8)
        try "the slow fox".write(to: temp.url.appending(path: "no.txt"), atomically: false, encoding: .utf8)
        #expect(find(temp.url, contains: "qUICK").found.names == ["yes.txt"])
    }

    @Test func nameAndContentMustBothMatch() throws {
        let temp = try TempFolder()
        try "needle".write(to: temp.url.appending(path: "a.md"), atomically: false, encoding: .utf8)
        try "needle".write(to: temp.url.appending(path: "a.txt"), atomically: false, encoding: .utf8)
        try "hay".write(to: temp.url.appending(path: "b.md"), atomically: false, encoding: .utf8)
        #expect(find(temp.url, name: "*.md", contains: "needle").found.names == ["a.md"])
    }

    @Test func contentIsFoundAcrossABlockEdge() throws {
        let temp = try TempFolder()
        var bytes = Data(repeating: 46, count: 1024 * 1024 - 3)
        bytes.append(Data("needle".utf8))
        try bytes.write(to: temp.url.appending(path: "split"))
        #expect(find(temp.url, contains: "needle").found.names == ["split"])
    }

    @Test func aMatchOnlyInTheLastBlockIsFound() throws {
        let temp = try TempFolder()
        var bytes = Data(repeating: 46, count: 3 * 1024 * 1024)
        bytes.append(Data("needle".utf8))
        try bytes.write(to: temp.url.appending(path: "tail"))
        #expect(find(temp.url, contains: "needle").found.names == ["tail"])
    }

    @Test func hiddenFilesAndWhatsInHiddenFoldersStayOutUnlessShown() throws {
        let temp = try TempFolder()
        try temp.file(".secret.md")
        try temp.file(".git/config.md")
        try temp.file("plain.md")
        #expect(find(temp.url, name: "*.md").found.names == ["plain.md"])
        #expect(find(temp.url, name: "*.md", hidden: true).found.names == [".secret.md", "config.md", "plain.md"])
    }

    @Test func packagesAreFilesAndAreNotEntered() throws {
        let temp = try TempFolder()
        try temp.file("Tool.app/Contents/notes.md")
        #expect(find(temp.url, name: "*.md").found.names.isEmpty)
        #expect(find(temp.url, name: "*.app").found.names == ["Tool.app"])
    }

    @Test func linksAreNeverFollowedOrRead() throws {
        let temp = try TempFolder()
        let outside = try TempFolder()
        try "needle".write(to: outside.url.appending(path: "file.txt"), atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: temp.url.appending(path: "folder"), withDestinationURL: outside.url)
        try FileManager.default.createSymbolicLink(
            at: temp.url.appending(path: "file"), withDestinationURL: outside.url.appending(path: "file.txt")
        )
        // A loop would never end if links were followed.
        try FileManager.default.createSymbolicLink(at: temp.url.appending(path: "loop"), withDestinationURL: temp.url)
        #expect(find(temp.url, contains: "needle").found.names.isEmpty)
        #expect(find(temp.url, name: "*.txt").found.names.isEmpty)
    }

    @Test func namedPipesAreNeverOpened() throws {
        let temp = try TempFolder()
        #expect(mkfifo(temp.url.appending(path: "pipe").path, 0o600) == 0)
        #expect(find(temp.url, contains: "needle").found.names.isEmpty)
    }

    @Test func whatCantBeReadIsCounted() throws {
        let temp = try TempFolder()
        let locked = try temp.folder("locked")
        try temp.file("locked/inside.md")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let result = find(temp.url, name: "*.md")
        #expect(result.outcome.unreadable == 1)
    }

    @Test func aFileThatCantBeReadIsCountedOnce() throws {
        let temp = try TempFolder()
        let file = try temp.file("secret.md")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        let result = find(temp.url, name: "*.md", contains: "text", spotlight: [URL(filePath: try #require(FileNames.realPath(file)))])
        #expect(result.outcome.unreadable == 1)
    }

    @Test func iCloudPlaceholdersAreNeverRead() throws {
        var info = stat()
        #expect(!FileFinder.isPlaceholder(info))
        info.st_flags = UInt32(SF_DATALESS)
        #expect(FileFinder.isPlaceholder(info))
    }

    @Test func aHitBelongsToTheDeepestRoot() {
        let roots = [URL(filePath: "/"), URL(filePath: "/Volumes/T7", directoryHint: .isDirectory)]
        #expect(FileFinder.root(of: URL(filePath: "/Volumes/T7/a.md"), in: roots)?.path == "/Volumes/T7")
        #expect(FileFinder.root(of: URL(filePath: "/Users/a.md"), in: roots)?.path == "/")
        #expect(FileFinder.root(of: URL(filePath: "/Volumes/T77/a.md"), in: [roots[1]]) == nil)
    }

    @Test func stoppingStops() throws {
        let temp = try TempFolder()
        for index in 0..<50 { try temp.file("f\(index).md") }
        let control = JobControl()
        control.cancel()
        #expect(find(temp.url, name: "*.md", control: control).found.names.isEmpty)
    }

    @Test func aMaskWithBracketsStaysOutOfSpotlight() {
        #expect(FindQuery(name: "[ab].md").spotlightPredicate == nil)
        #expect(FindQuery().spotlightPredicate == nil)
    }
}

// Serialized, because making a disk image blocks a thread that the rest of the tests are waiting for.
@Suite(.serialized) struct SpotlightMergeTests {
    /// Spotlight can only ever make results arrive sooner, so what it says never changes the answer.
    @Test func hitsAreCheckedAndNeverRepeated() throws {
        let temp = try TempFolder()
        let real = URL(filePath: try #require(FileNames.realPath(temp.url)), directoryHint: .isDirectory)
        try temp.file("plain.md")
        try temp.file(".git/hidden.md")
        try temp.file("Tool.app/Contents/inner.md")
        try temp.file("other.txt")
        let hits = ["plain.md", ".git/hidden.md", "Tool.app/Contents/inner.md", "other.txt", "gone.md"].map { real.appending(path: $0) }
        let outside = URL(filePath: "/etc/hosts.md")
        let result = find(temp.url, name: "*.md", spotlight: hits + [outside])
        #expect(result.found.names == ["plain.md"])
    }

    @Test func spotlightMissingEverythingStillFindsEverything() throws {
        let temp = try TempFolder()
        try temp.file("a.md")
        try temp.file("sub/b.md")
        #expect(find(temp.url, name: "*.md", spotlight: []).found.names == ["a.md", "b.md"])
    }

    @Test func spotlightNamesRealFiles() {
        // Calculator has been in this folder for as long as this OS has existed.
        let hits = SpotlightHits()
        Spotlight.run(FindQuery(name: "Calculator.app"), in: [URL(filePath: "/System/Applications")], hits: hits, control: JobControl())
        #expect(hits.take().map(\.path).contains("/System/Applications/Calculator.app"))
    }

    @Test func spotlightSearchesFromTheTopOfTheDisk() {
        let hits = SpotlightHits()
        Spotlight.run(FindQuery(name: "Calculator.app"), in: [URL(filePath: "/")], hits: hits, control: JobControl())
        #expect(hits.take().map(\.path).contains("/System/Applications/Calculator.app"))
    }

    /// Spotlight raises an exception nothing can catch on what it can't parse, so typing must never reach that.
    @Test func nothingTypedCanUpsetSpotlight() {
        let texts = ["a\"b", "a'b", "a\\", "(", ")", "not a ( query", "%@", "%K", "$x", "a == b", "\n", "é", "日本語", "*", "?", ",", "a,,b", "\"cd", "a, b"]
        let stopped = JobControl()
        stopped.cancel()
        for text in texts {
            for query in [FindQuery(name: text), FindQuery(contains: text), FindQuery(name: text, contains: text)] {
                Spotlight.run(query, in: [URL(filePath: "/System/Applications")], hits: SpotlightHits(), control: stopped)
            }
        }
    }

    @Test func theSameTreeGivesTheSameAnswerOnAnyVolume() throws {
        let image = try DiskImage(format: "APFS")
        let temp = try TempFolder()
        for root in [image.mount, temp.url] {
            for name in ["docs/a.md", "docs/deep/b.md", "c.txt"] {
                let url = root.appending(path: name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "needle".write(to: url, atomically: false, encoding: .utf8)
            }
        }
        #expect(find(image.mount, name: "*.md").found.names == find(temp.url, name: "*.md").found.names)
        #expect(find(image.mount, contains: "needle").found.names == find(temp.url, contains: "needle").found.names)
    }

    @Test func otherVolumesAreNotEnteredFromAbove() throws {
        let image = try DiskImage(format: "APFS")
        try "x".write(to: image.mount.appending(path: "on-image.md"), atomically: false, encoding: .utf8)
        // The image is mounted under this folder.
        #expect(find(image.mount.deletingLastPathComponent(), name: "on-image.md").found.names.isEmpty)
    }
}

@Suite(.serialized) struct FindScopeTests {
    @Test func aFolderIsItself() throws {
        let temp = try TempFolder()
        let roots = FindScope.folder.roots(from: temp.url, volumes: [])
        #expect(roots.map(\.path) == [FileNames.realPath(temp.url)])
    }

    @Test func aVolumeIsItsRoot() throws {
        let image = try DiskImage(format: "APFS")
        let folder = try { () throws -> URL in
            let url = image.mount.appending(path: "sub", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }()
        #expect(FindScope.volume.roots(from: folder, volumes: []).map(\.path) == [FileNames.realPath(image.mount)])
    }

    @Test func theStartupDiskIsSearchedFromTheTop() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(FindScope.volume.roots(from: home, volumes: []).map(\.path) == ["/"])
    }

    @Test func allVolumesListsEachOnce() throws {
        let image = try DiskImage(format: "APFS")
        let mount = URL(filePath: try #require(FileNames.realPath(image.mount)), directoryHint: .isDirectory)
        let roots = FindScope.allVolumes.roots(from: mount, volumes: [mount, URL(filePath: "/")])
        #expect(roots.map(\.path) == [mount.path, "/"])
    }
}

@MainActor
@Suite struct FindSessionTests {
    private func setup(_ temp: TempFolder) async throws -> Workspace {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        return app
    }

    /// Searches the left panel's folder, and leaves the results showing.
    private func search(_ app: Workspace, _ name: String = "", contains: String = "") async throws -> FindSession {
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query = FindQuery(name: name, contains: contains)
        await session.finished()
        await app.active.loaded()
        return session
    }

    @Test func aSearchOpensATabAndCancellingTakesItAway() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        let session = try await search(app, "*.md")
        #expect(app.active.tabs.count == 2)
        #expect(app.active.tab.title == "Find: *.md")
        #expect(app.active.rows.map(\.fileName) == ["one.md"])
        #expect(app.isFindBarOpen)
        #expect(app.isTyping)
        app.cancelFind()
        #expect(app.active.tabs.count == 1)
        #expect(!app.active.isResults)
        #expect(!session.isBarOpen)
    }

    @Test func typingStartsOverWithTheNewAnswer() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        try temp.file("a/two.txt")
        let app = try await setup(temp)
        let session = try await search(app, "*.md")
        session.query.name = "*.txt"
        await session.finished()
        await app.active.loaded()
        #expect(app.active.rows.map(\.fileName) == ["two.txt"])
        #expect(app.active.tab.title == "Find: *.txt")
    }

    @Test func clearingTheFieldsLeavesNothingBehind() async throws {
        let temp = try TempFolder()
        // Sparse files, which take a moment to search and none to make. Many small ones
        // would be made on the main actor and hold up every other test.
        for index in 0..<60 { #expect(truncate(try temp.file("a/file\(index).md").path, 1024 * 1024) == 0) }
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.contains = "nothing has this"
        try await Task.sleep(for: .milliseconds(230))
        session.query = FindQuery()
        await session.finished()
        await app.active.loaded()
        #expect(app.active.rows.isEmpty)
        #expect(app.active.tab.title == "Find")
        #expect(app.active.findStatus == nil)
    }

    @Test func aLoadFromTheLastSearchCantLandOnTheNext() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        try temp.file("a/two.txt")
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.name = "*.md"
        await session.finished()
        // The first search's refresh is still running at this point.
        session.query.name = "*.txt"
        await session.finished()
        await app.active.loaded()
        #expect(app.active.rows.map(\.fileName) == ["two.txt"])
    }

    @Test func filesDifferingOnlyByCaseStillCompress() async throws {
        let image = try await Task.detached { try DiskImage(format: "Case-sensitive APFS") }.value
        let (a, b) = (image.mount.appending(path: "a"), image.mount.appending(path: "b"))
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for name in ["README", "readme"] { try Data().write(to: a.appending(path: name)) }
        let app = Workspace(left: a, right: b)
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        app.active.markAll()
        app.beginCompress()
        #expect(app.pending?.preview.items.count == 2)
    }

    @Test func theCursorKeepsAFolderWhoseURLChangedShape() async throws {
        let temp = try TempFolder()
        let file = try temp.file("a/file")
        let folder = try temp.folder("a/folder")
        let app = try await setup(temp)
        let panel = app.active
        let id = UUID()
        panel.openResults(id)
        await panel.loaded()
        let slashed = URL(filePath: folder.path + "/", directoryHint: .isDirectory)
        #expect(panel.addResults([try #require(LocalSource.entry(file)), try #require(LocalSource.entry(slashed))], to: id))
        panel.setCursor(1)
        panel.finishResults(id, FindOutcome(), isComplete: true)
        await panel.loaded()
        #expect(panel.cursorEntry?.fileName == "folder")
    }

    @Test func keepingLeavesTheTabAndGivesBackTheKeyboard() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        let focus = app.focusTick
        app.keepFind()
        #expect(!app.isFindBarOpen)
        #expect(app.active.isResults)
        #expect(app.focusTick == focus + 1)
    }

    @Test func aResultHasNoParentRow() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        #expect(app.active.rows.first?.isParent == false)
        #expect(app.active.tab.parent == nil)
    }

    @Test func returnOpensTheFolderAndBackReturnsToTheResults() async throws {
        let temp = try TempFolder()
        try temp.file("a/sub/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.openCursor()
        await app.active.loaded()
        #expect(!app.active.isResults)
        #expect(app.active.location.lastPathComponent == "sub")
        #expect(app.active.cursorEntry?.fileName == "one.md")
        app.active.goBack()
        await app.active.loaded()
        #expect(app.active.isResults)
        #expect(app.active.rows.map(\.fileName) == ["one.md"])
    }

    @Test func aResultCopiesToTheOtherPanel() async throws {
        let temp = try TempFolder()
        try temp.file("a/sub/one.md", bytes: 5)
        try temp.file("a/deep/down/two.md", bytes: 5)
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.markAll()
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "b/one.md").path))
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "b/two.md").path))
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "a/sub/one.md").path))
    }

    @Test func twoResultsWithOneNameAreRefusedRatherThanOverwritten() async throws {
        let temp = try TempFolder()
        try temp.file("a/one/same.md")
        try temp.file("a/two/same.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.markAll()
        app.begin(.copy)
        await app.planned()
        #expect(app.pending == nil)
        #expect(app.message == OperationRefusal.sharedName("same.md").message)
    }

    @Test func compressingTwoResultsWithOneNameIsRefused() async throws {
        let temp = try TempFolder()
        try temp.file("a/one/same.md")
        try temp.file("a/two/same.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.markAll()
        app.beginCompress()
        #expect(app.pending == nil)
    }

    @Test func resultsCompress() async throws {
        let temp = try TempFolder()
        try temp.file("a/one/first.md")
        try temp.file("a/two/second.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.markAll()
        app.beginCompress()
        #expect(app.pending?.preview.items.count == 2)
    }

    @Test func moveAndTrashNeedTheRealFolder() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        for kind in [OperationKind.move, .trash, .delete] {
            app.begin(kind)
            await app.planned()
            #expect(app.pending == nil)
        }
        #expect(FileManager.default.fileExists(atPath: temp.url.appending(path: "a/one.md").path))
    }

    @Test func nothingLandsInAResultsTab() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        try temp.file("b/two.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.activate(1)
        app.active.setCursor(1)
        app.begin(.copy)
        await app.planned()
        #expect(app.pending == nil)
        #expect(app.message == "Switch the other panel away from the results first.")
        app.beginCompress()
        #expect(app.pending == nil)
    }

    @Test func renamingAndNewFoldersNeedAFolder() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.beginRename()
        #expect(app.active.edit == nil)
        app.active.beginNewFolder()
        #expect(app.active.edit == nil)
        app.beginRename()
        #expect(app.renameSession == nil)
        app.beginCompare()
        #expect(app.compareSession == nil)
    }

    @Test func aFileThatGoesDropsOutOnRefresh() async throws {
        let temp = try TempFolder()
        let file = try temp.file("a/one.md")
        try temp.file("a/two.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        try FileManager.default.removeItem(at: file)
        app.active.refresh()
        await app.active.loaded()
        #expect(app.active.rows.map(\.fileName) == ["two.md"])
    }

    @Test func theFolderColumnSorts() async throws {
        let temp = try TempFolder()
        try temp.file("a/zed/a.md")
        try temp.file("a/alpha/b.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.sort(by: .ext)
        await app.active.loaded()
        #expect(app.active.rows.map(\.fileName) == ["b.md", "a.md"])
        #expect(app.active.tab.sort.key == .folder)
    }

    @Test func sameNamesKeepTheirOwnRowsAndCursors() async throws {
        let temp = try TempFolder()
        try temp.file("a/one/same.md")
        try temp.file("a/two/same.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.setCursor(1)
        let url = app.active.cursorEntry?.url
        app.active.refresh()
        await app.active.loaded()
        #expect(app.active.cursorEntry?.url == url)
    }

    @Test func escClearsMarksThenClosesTheTab() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.markAll()
        app.escape(in: app.active)
        #expect(app.active.isResults)
        #expect(app.active.markedCount == 0)
        app.escape(in: app.active)
        #expect(!app.active.isResults)
        #expect(app.active.tabs.count == 1)
    }

    @Test func escOnAnOrdinaryFolderStillClearsMarks() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        app.active.markAll()
        app.escape(in: app.active)
        #expect(app.active.markedCount == 0)
    }

    @Test func closingTheOnlyTabLeavesTheFolder() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.selectTab(0)
        await app.active.loaded()
        app.active.closeTab()
        await app.active.loaded()
        #expect(app.active.tabs.count == 1)
        app.escape(in: app.active)
        await app.active.loaded()
        #expect(!app.active.isResults)
        #expect(app.active.rows.contains { $0.fileName == "one.md" })
    }

    @Test func aStoppedSearchSaysSoRatherThanPassingForTheWholeAnswer() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.name = "*.md"
        #expect(app.active.findStatus == "Searching…")
        session.stop()
        #expect(app.active.findStatus == "Stopped")
    }

    @Test func escStopsARunningSearchBeforeClosingItsTab() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.name = "*.md"
        app.keepFind()
        #expect(session.isSearching)
        app.escape(in: app.active)
        #expect(!session.isSearching)
        #expect(app.active.isResults)
        #expect(app.active.findStatus == "Stopped")
        app.escape(in: app.active)
        #expect(!app.active.isResults)
    }

    @Test func aSearchSaysHowItEnded() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        let session = try await search(app, "*.md")
        #expect(session.summary == "1 item found")
        session.query = FindQuery()
        #expect(session.summary == nil)
        session.query.name = "*.md"
        #expect(session.summary == nil)
        session.stop()
        #expect(session.summary == "0 items found. Stopped")
    }

    @Test func leavingForAnotherTabClosesTheBarAndGivesBackTheKeyboard() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        let focus = app.focusTick
        app.active.selectTab(0)
        #expect(!app.isFindBarOpen)
        #expect(app.focusTick > focus)
        #expect(app.active.tabs.count == 2)
    }

    @Test func aSearchThatNeverStartedLeavesNoTab() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.beginFind()
        app.active.selectTab(0)
        await app.active.loaded()
        #expect(app.active.tabs.count == 1)
        #expect(app.active.tabIndex == 0)
    }

    @Test func sortsCrossBetweenFoldersAndResults() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        app.active.sort(by: .ext)
        await app.active.loaded()
        _ = try await search(app, "*.md")
        app.keepFind()
        #expect(app.active.tab.sort.key == .folder)
        app.active.newTab()
        await app.active.loaded()
        #expect(app.active.tab.sort.key == .ext)
        app.active.closeTab()
        await app.active.loaded()
        app.active.openCursor()
        await app.active.loaded()
        #expect(app.active.tab.sort.key == .ext)
        app.active.goBack()
        await app.active.loaded()
        #expect(app.active.tab.sort.key == .folder)
    }

    @Test func theOnlyTabLeavesResultsSortedByWhatItShows() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        _ = try await search(app, "*.md")
        app.keepFind()
        app.active.sort(by: .ext)
        await app.active.loaded()
        app.active.selectTab(0)
        await app.active.loaded()
        app.active.closeTab()
        await app.active.loaded()
        app.escape(in: app.active)
        await app.active.loaded()
        #expect(app.active.tab.sort.key == .ext)
    }

    @Test func aNewSearchStopsTheLastOne() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.beginFind()
        let first = try #require(app.find)
        first.query.name = "x"
        app.keepFind()
        app.beginFind()
        #expect(!first.isSearching)
        #expect(app.find !== first)
        #expect(app.active.tabs.count == 3)
    }

    @Test func noBarOpensOverAnother() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.beginFind()
        let first = app.find
        app.beginFind()
        #expect(app.find === first)
        app.beginGoTo()
        app.isGoingToPath = false
        app.cancelFind()
    }

    @Test func aSearchRunsOnInAnotherTab() async throws {
        let temp = try TempFolder()
        try temp.file("a/one.md")
        let app = try await setup(temp)
        app.beginFind()
        let session = try #require(app.find)
        session.scope = .folder
        session.query.name = "*.md"
        app.keepFind()
        app.active.selectTab(0)
        await session.finished()
        app.active.selectTab(1)
        await app.active.loaded()
        #expect(app.active.rows.map(\.fileName) == ["one.md"])
        #expect(app.active.findStatus == nil)
    }

    @Test func itsInThePalette() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        #expect(app.commands(matching: "find files").first?.keys == "⌘F")
        let stop = try #require(app.commands.first { $0.title == "Stop Search" })
        #expect(!stop.isEnabled)
    }
}
