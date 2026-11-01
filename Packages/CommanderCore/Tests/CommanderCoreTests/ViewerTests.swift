import Foundation
import Testing
@testable import CommanderCore

@Suite struct PagedFileTests {
    private func file(_ text: String, in temp: TempFolder) throws -> PagedFile {
        let url = temp.url.appending(path: "text")
        try Data(text.utf8).write(to: url)
        return try PagedFile(url)
    }

    /// `deinit` closes the file on every way out, and closing it here as well would close it twice.
    @Test func aRefusedFileIsClosedExactlyOnce() throws {
        let temp = try TempFolder()
        for _ in 0..<20_000 {
            #expect(throws: ViewerError.notAFile) { _ = try PagedFile(temp.url) }
        }
        let file = try temp.file("still-opens", bytes: 1)
        #expect(throws: Never.self) { _ = try PagedFile(file) }
    }

    @Test func readsRowsAndTheirOffsets() throws {
        let temp = try TempFolder()
        let rows = try file("one\ntwo\n\nfour", in: temp).rows(from: 0, count: 10, columns: 80)
        #expect(rows.map(\.text) == ["one", "two", "", "four"])
        #expect(rows.map(\.offset) == [0, 4, 8, 9])
        #expect(rows[3].next == 13)
    }

    @Test func wrapsLongLinesWithoutSplittingACharacter() throws {
        let temp = try TempFolder()
        let rows = try file("ééééé\n", in: temp).rows(from: 0, count: 5, columns: 2)
        #expect(rows.map(\.text) == ["éé", "éé", "é"])
    }

    @Test func expandsTabsAndHidesControlCharacters() throws {
        let temp = try TempFolder()
        let rows = try file("a\tb\r\nc\u{1}d", in: temp).rows(from: 0, count: 5, columns: 80)
        #expect(rows.map(\.text) == ["a    b", "c·d"])
    }

    @Test func stepsBackByRows() throws {
        let temp = try TempFolder()
        let paged = try file("one\ntwo\nthree\n", in: temp)
        #expect(paged.start(rowsBefore: 14, count: 1, columns: 80) == 8)
        #expect(paged.start(rowsBefore: 14, count: 2, columns: 80) == 4)
        #expect(paged.start(rowsBefore: 8, count: 9, columns: 80) == 0)
        #expect(paged.start(rowsBefore: 0, count: 1, columns: 80) == 0)
    }

    @Test func stepsBackThroughWrappedRows() throws {
        let temp = try TempFolder()
        let paged = try file("aaaabbbbcc\nd\n", in: temp)
        #expect(paged.start(rowsBefore: 11, count: 1, columns: 4) == 8)
        #expect(paged.start(rowsBefore: 11, count: 3, columns: 4) == 0)
    }

    @Test func aJumpLandsOnARowStart() throws {
        let temp = try TempFolder()
        let paged = try file("one\ntwo\nthree\n", in: temp)
        #expect(paged.rowStart(near: 6) == 4)
        #expect(paged.rowStart(near: 8) == 8)
        #expect(paged.rowStart(near: 500) == 8)
        #expect(paged.rowStart(near: 0) == 0)
    }

    @Test func aJumpDeepIntoALongLineStaysThere() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "minified")
        try Data(String(repeating: "é", count: 500_000).utf8).write(to: url)
        let paged = try PagedFile(url)
        #expect(paged.rowStart(near: 500_000) == 500_000)
        #expect(paged.rowStart(near: 500_001) == 500_002)
        #expect(paged.rows(from: 500_002, count: 1, columns: 3).first?.text == "ééé")
    }

    @Test func theLastRowsOfALongLastLineCanBeFound() throws {
        let temp = try TempFolder()
        let paged = try file(String(repeating: "x", count: 1_000), in: temp)
        let start = paged.start(rowsBefore: paged.size, count: 2, columns: 10)
        #expect(paged.rows(from: start, count: 2, columns: 10).last?.next == 1_000)
    }

    @Test func aHugeFileOpensAtOnceAndReadsAtBothEnds() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "huge.log")
        try Data("first line\n".utf8).write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        let end: UInt64 = 6 * 1024 * 1024 * 1024
        try handle.seek(toOffset: end)
        try handle.write(contentsOf: Data("\nnext to last\nlast line\n".utf8))
        try handle.close()

        let clock = ContinuousClock()
        var tail: [PagedFile.Row] = []
        let elapsed = try clock.measure {
            let paged = try PagedFile(url)
            #expect(paged.rows(from: 0, count: 1, columns: 80).first?.text == "first line")
            let start = paged.start(rowsBefore: paged.size, count: 2, columns: 80)
            tail = paged.rows(from: start, count: 2, columns: 80)
            #expect(paged.rowStart(near: Int64(end) + 16) == Int64(end) + 14)
        }
        #expect(tail.map(\.text) == ["next to last", "last line"])
        #expect(elapsed < .milliseconds(200))
    }

    @Test func aFileThatShrinksIsReadAsShorterRatherThanCrashing() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "log")
        try Data(repeating: 0x41, count: 100_000).write(to: url)
        let paged = try PagedFile(url)
        try Data().write(to: url)
        #expect(paged.rows(from: 50_000, count: 5, columns: 80).isEmpty)
        #expect(paged.start(rowsBefore: 50_000, count: 5, columns: 80) == 0)
    }

    @Test func aGrowingFileShowsItsNewSize() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "log")
        try Data("a\n".utf8).write(to: url)
        let paged = try PagedFile(url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("b\n".utf8))
        try handle.close()
        #expect(paged.size == 4)
    }

    @Test func aPipeIsRefusedInsteadOfHanging() throws {
        let temp = try TempFolder()
        let pipe = temp.url.appending(path: "pipe")
        #expect(mkfifo(pipe.path, 0o644) == 0)
        #expect(throws: ViewerError.notAFile) { _ = try PagedFile(pipe) }
    }

    @Test func tellsBinaryFromText() throws {
        let temp = try TempFolder()
        #expect(try !file("héllo\n", in: temp).looksBinary)
        let url = temp.url.appending(path: "binary")
        try Data([0x41, 0x00, 0x42]).write(to: url)
        #expect(try PagedFile(url).looksBinary)
        try Data([0xFF, 0xFE, 0x41]).write(to: url)
        #expect(try PagedFile(url).looksBinary)
    }

    @Test func aCharacterCutByTheSampleIsStillText() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "long")
        try Data((String(repeating: "a", count: 8191) + "é\n").utf8).write(to: url)
        #expect(try !PagedFile(url).looksBinary)
    }

    @Test func formatsHexRows() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "bytes")
        try Data("Hello, world!!!!Z".utf8).write(to: url)
        let rows = try PagedFile(url).hexRows(from: 0, count: 2, width: 16)
        #expect(rows[0].text == "000000000000  48 65 6c 6c 6f 2c 20 77  6f 72 6c 64 21 21 21 21  |Hello, world!!!!|")
        #expect(rows[1].offset == 16)
        #expect(rows[1].text.hasPrefix("000000000010  5a "))
        #expect(rows[1].text.hasSuffix(" |Z|"))
        #expect(rows[1].text.count - 1 == rows[0].text.count - 16)
    }

    @Test func hexRowsFitTheirColumns() throws {
        let temp = try TempFolder()
        let url = temp.url.appending(path: "bytes")
        try Data(repeating: 0, count: 64).write(to: url)
        let paged = try PagedFile(url)
        for columns in [60, 82, 83, 120] {
            let width = PagedFile.hexWidth(columns: columns)
            #expect(paged.hexRows(from: 0, count: 1, width: width)[0].text.count <= columns)
        }
    }
}

@MainActor
@Suite struct ViewerTests {
    private func entry(_ url: URL, isDirectory: Bool = false) -> FileEntry {
        FileEntry(url: url, fileName: url.lastPathComponent, size: 1, modified: .now, isDirectory: isDirectory)
    }

    @Test func picksAModeForEachKindOfFile() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let text = temp.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        viewer.follow(entry(text))
        await viewer.loaded()
        #expect(viewer.mode == .text)
        let binary = temp.url.appending(path: "tool")
        try Data([0, 1, 2]).write(to: binary)
        viewer.follow(entry(binary))
        await viewer.loaded()
        #expect(viewer.mode == .hex)
        let image = temp.url.appending(path: "photo.png")
        try Data([0, 1, 2]).write(to: image)
        viewer.follow(entry(image))
        await viewer.loaded()
        #expect(viewer.mode == .quickLook)
    }

    @Test func foldersAndEmptyFilesExplainThemselves() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        viewer.follow(entry(try temp.folder("tree"), isDirectory: true))
        await viewer.loaded()
        #expect(viewer.notice == "Move the cursor to a file to view it.")
        #expect(viewer.file == nil)
        viewer.follow(entry(try temp.file("empty", bytes: 0)))
        await viewer.loaded()
        #expect(viewer.notice == "This file is empty.")
    }

    @Test func aPackageExplainsItself() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let package = FileEntry(url: try temp.folder("Thing.app"), fileName: "Thing.app", size: nil, modified: .now, isDirectory: true, isPackage: true)
        viewer.follow(package)
        await viewer.loaded()
        #expect(viewer.notice == "Move the cursor to a file to view it.")
    }

    @Test func aSavedFileReloadsAndKeepsItsView() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let url = temp.url.appending(path: "notes.txt")
        try Data("old".utf8).write(to: url)
        let before = FileEntry(url: url, fileName: "notes.txt", size: 3, modified: Date(timeIntervalSince1970: 1), isDirectory: false)
        viewer.follow(before)
        await viewer.loaded()
        viewer.toggleHex()
        try Data("newer".utf8).write(to: url, options: .atomic)
        var after = before
        after.size = 5
        after.modified = Date(timeIntervalSince1970: 2)
        viewer.follow(after)
        await viewer.loaded()
        #expect(viewer.file?.size == 5)
        #expect(viewer.mode == .hex)
    }

    @Test func aMissingFileSaysSo() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        viewer.follow(entry(temp.url.appending(path: "gone")))
        await viewer.loaded()
        #expect(viewer.notice == "This file can't be read.")
    }

    @Test func hexTogglesAndReturns() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let text = temp.url.appending(path: "notes.txt")
        try Data("hello".utf8).write(to: text)
        viewer.follow(entry(text))
        await viewer.loaded()
        viewer.toggleHex()
        #expect(viewer.mode == .hex)
        viewer.toggleHex()
        #expect(viewer.mode == .text)
    }

    @Test func aBinaryFileCanStillBeReadAsText() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let binary = temp.url.appending(path: "tool")
        try Data([0x41, 0, 0x42]).write(to: binary)
        viewer.follow(entry(binary))
        await viewer.loaded()
        #expect(viewer.mode == .hex)
        viewer.toggleHex()
        #expect(viewer.mode == .text)
    }

    @Test func onlyTheNewestFileShows() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let first = entry(try temp.file("first", bytes: 1))
        let second = entry(try temp.file("second", bytes: 2))
        viewer.follow(first)
        viewer.follow(second)
        await viewer.loaded()
        #expect(viewer.title == "second")
        #expect(viewer.file?.size == 2)
        viewer.follow(first)
        viewer.pin(try temp.file("output", bytes: 3), title: "Output of ls", cursor: first)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewer.title == "Output of ls")
        #expect(viewer.file?.size == 3)
    }

    @Test func theTitleAndContentChangeTogether() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        viewer.follow(entry(try temp.file("first", bytes: 1)))
        await viewer.loaded()
        viewer.follow(entry(try temp.file("second", bytes: 2)))
        #expect(viewer.title == "first")
        #expect(viewer.file?.size == 1)
        await viewer.loaded()
        #expect(viewer.title == "second")
        #expect(viewer.file?.size == 2)
    }

    @Test func aPinnedFileStaysUntilTheCursorMoves() async throws {
        let temp = try TempFolder()
        let viewer = Viewer()
        let cursor = entry(try temp.file("cursor", bytes: 1))
        let other = entry(try temp.file("other", bytes: 1))
        viewer.follow(cursor)
        await viewer.loaded()
        viewer.pin(try temp.file("output", bytes: 1), title: "Output of ls", cursor: cursor)
        viewer.follow(cursor)
        await viewer.loaded()
        #expect(viewer.title == "Output of ls")
        viewer.follow(other)
        await viewer.loaded()
        #expect(viewer.title == "other")
    }
}
