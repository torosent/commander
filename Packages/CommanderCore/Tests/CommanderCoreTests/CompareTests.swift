import Darwin
import Foundation
import Testing
@testable import CommanderCore

private func write(_ text: String, _ url: URL, age: TimeInterval = 0) throws {
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + age)], ofItemAtPath: url.path)
}

/// Compares `a` and `b` inside a temp folder.
private func compare(_ temp: TempFolder, mode: CompareMode = .nameAndDate, hidden: Bool = false) throws -> [CompareRow] {
    try TreeComparer(mode: mode, showHidden: hidden).compare(temp.url.appending(path: "a"), temp.url.appending(path: "b"))
}

private func row(_ rows: [CompareRow], _ name: String) throws -> CompareRow {
    try #require(rows.first { $0.name == name })
}

@Suite struct TreeComparerTests {
    private func folders(_ temp: TempFolder) throws -> (URL, URL) {
        (try temp.folder("a"), try temp.folder("b"))
    }

    @Test func sameFilesAreSameAndNothingHappens() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("x", a.appending(path: "f"))
        try write("x", b.appending(path: "f"))
        let found = try row(compare(temp), "f")
        #expect(found.verdict == .same)
        #expect(found.action == .none)
    }

    @Test func theNewerSideGoesOverTheOlder() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("new", a.appending(path: "f"), age: 100)
        try write("old", b.appending(path: "f"))
        try write("old", a.appending(path: "g"))
        try write("new", b.appending(path: "g"), age: 100)
        let rows = try compare(temp)
        #expect(try row(rows, "f").action == .toRight)
        #expect(try row(rows, "g").action == .toLeft)
    }

    @Test func aFileOnOneSideCopiesAcrossAndIsNeverDeletedByDefault() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("x", a.appending(path: "left"))
        try write("x", b.appending(path: "right"))
        let rows = try compare(temp)
        #expect(try row(rows, "left").action == .toRight)
        #expect(try row(rows, "right").action == .toLeft)
        #expect(!rows.contains { $0.action == .trash })
    }

    @Test func theSameDateWithDifferentSizesIsAMismatchWithNoWinner() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("short", a.appending(path: "f"))
        try write("much longer", b.appending(path: "f"))
        let found = try row(compare(temp), "f")
        #expect(found.verdict == .different)
        #expect(found.action == .skip)
    }

    @Test func sizeModeIgnoresDates() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("abc", a.appending(path: "f"), age: 500)
        try write("xyz", b.appending(path: "f"))
        #expect(try row(compare(temp, mode: .size), "f").verdict == .same)
    }

    @Test func contentModeSeesThroughSizeAndDate() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("abc", a.appending(path: "f"))
        try write("xyz", b.appending(path: "f"))
        try write("same", a.appending(path: "g"), age: 500)
        try write("same", b.appending(path: "g"))
        let rows = try compare(temp, mode: .content)
        #expect(try row(rows, "f").verdict == .different)
        #expect(try row(rows, "g").verdict == .same)
    }

    @Test func bytesAreComparedToTheVeryEnd() throws {
        let temp = try TempFolder()
        var bytes = Data(repeating: 7, count: 600_000)
        let first = temp.url.appending(path: "one")
        let second = temp.url.appending(path: "two")
        try bytes.write(to: first)
        try bytes.write(to: second)
        #expect(try TreeComparer.sameBytes(first, second, control: JobControl()) == true)
        bytes[599_999] = 8
        try bytes.write(to: second)
        #expect(try TreeComparer.sameBytes(first, second, control: JobControl()) == false)
    }

    @Test func aDifferenceInTheFirstBlockStopsTheRead() throws {
        // Stopping can't be seen from the result, so this proves it by time on a sparse 8 GB pair.
        let temp = try TempFolder()
        let first = temp.url.appending(path: "one")
        let second = temp.url.appending(path: "two")
        for (url, byte) in [(first, UInt8(1)), (second, UInt8(2))] {
            try Data([byte]).write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 8 * 1024 * 1024 * 1024)
            try handle.close()
        }
        let start = ContinuousClock.now
        #expect(try TreeComparer.sameBytes(first, second, control: JobControl()) == false)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func foldersOnBothSidesAreWalked() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try temp.folder("a/sub")
        try temp.folder("b/sub")
        try write("x", a.appending(path: "sub/deep"))
        let rows = try compare(temp)
        #expect(try row(rows, "sub").isHeader)
        #expect(try row(rows, "deep").depth == 1)
        #expect(try row(rows, "deep").rightFolder.lastPathComponent == "sub")
        _ = b
    }

    @Test func aFolderOnOneSideIsOneRow() throws {
        let temp = try TempFolder()
        let (a, _) = try folders(temp)
        try temp.folder("a/only")
        try write("x", a.appending(path: "only/inside"))
        let rows = try compare(temp)
        #expect(rows.map(\.name) == ["only"])
        #expect(try row(rows, "only").action == .toRight)
    }

    @Test func aFileAgainstAFolderDoesNothing() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        try write("x", a.appending(path: "thing"))
        try temp.folder("b/thing")
        _ = b
        let found = try row(compare(temp), "thing")
        #expect(found.verdict == .clash)
        #expect(found.action == .none)
    }

    @Test func linksAreComparedAsLinksAndNotFollowed() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        let outside = try temp.folder("outside")
        try write("x", outside.appending(path: "secret"))
        try FileManager.default.createSymbolicLink(atPath: a.appending(path: "door").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: b.appending(path: "door").path, withDestinationPath: outside.path)
        let rows = try compare(temp, mode: .content)
        #expect(!rows.contains { $0.name == "secret" })
        #expect(try row(rows, "door").verdict == .same)
    }

    @Test func hiddenFilesStayOutUnlessShown() throws {
        let temp = try TempFolder()
        let (a, _) = try folders(temp)
        try write("x", a.appending(path: ".secret"))
        #expect(try compare(temp).isEmpty)
        #expect(try compare(temp, hidden: true).count == 1)
    }

    @Test func systemClutterIsNeverADifference() throws {
        let temp = try TempFolder()
        let (a, _) = try folders(temp)
        try write("x", a.appending(path: ".DS_Store"))
        try write("x", a.appending(path: "._fork"))
        #expect(try compare(temp, hidden: true).isEmpty)
    }

    @Test func aFolderThatCantBeReadIsNotTreatedAsEmpty() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        let locked = try temp.folder("a/locked")
        try temp.folder("b/locked")
        try write("x", b.appending(path: "locked/inside"))
        try write("x", b.appending(path: "other"))
        _ = a
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let rows = try compare(temp)
        #expect(try row(rows, "locked").verdict == .unreadable)
        // Its contents would otherwise look missing from the left and be offered for copying.
        #expect(!rows.contains { $0.name == "inside" })
        #expect(rows.contains { $0.name == "other" })
    }

    @Test func aFileThatCantBeReadIsNotOfferedForOverwriting() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        let locked = a.appending(path: "f")
        try write("abc", locked)
        try write("xyz", b.appending(path: "f"), age: 100)
        try write("longer", b.appending(path: "g"), age: 100)
        let other = a.appending(path: "g")
        try write("abc", other)
        for file in [locked, other] { try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path) }
        defer { for file in [locked, other] { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) } }
        let rows = try compare(temp, mode: .content)
        for name in ["f", "g"] {
            #expect(try row(rows, name).verdict == .unreadable)
            #expect(try row(rows, name).action == .none)
        }
    }

    @Test func namedPipesAreNeverOpened() throws {
        let temp = try TempFolder()
        let (a, b) = try folders(temp)
        #expect(mkfifo(a.appending(path: "pipe").path, 0o600) == 0)
        #expect(mkfifo(b.appending(path: "pipe").path, 0o600) == 0)
        let found = try row(compare(temp, mode: .content), "pipe")
        #expect(found.verdict == .unreadable)
        #expect(found.action == .none)
    }

    @Test func aRootThatCantBeReadFailsOutright() throws {
        let temp = try TempFolder()
        _ = try temp.folder("a")
        #expect(throws: OperationError.self) { _ = try compare(temp) }
    }

    @Test func stoppingStops() throws {
        let temp = try TempFolder()
        let (a, _) = try folders(temp)
        try write("x", a.appending(path: "f"))
        let control = JobControl()
        control.cancel()
        #expect(throws: OperationError.cancelled) {
            _ = try TreeComparer(mode: .nameAndDate, showHidden: false, control: control)
                .compare(temp.url.appending(path: "a"), temp.url.appending(path: "b"))
        }
    }
}

@Suite struct VolumeRulesTests {
    @Test func caseDoesntMakeADifferenceWhenOneSideIgnoresIt() throws {
        let sensitive = try DiskImage(format: "Case-sensitive APFS")
        let ordinary = try DiskImage(format: "APFS")
        try write("x", sensitive.mount.appending(path: "README.md"))
        try write("x", ordinary.mount.appending(path: "readme.md"))
        let rows = try TreeComparer(mode: .nameAndDate, showHidden: false).compare(sensitive.mount, ordinary.mount)
        #expect(rows.count == 1)
        #expect(rows[0].verdict == .same)
    }

    @Test func caseIsADifferenceWhenBothSidesKeepIt() throws {
        let first = try DiskImage(format: "Case-sensitive APFS")
        let second = try DiskImage(format: "Case-sensitive APFS")
        try write("x", first.mount.appending(path: "README.md"))
        try write("x", second.mount.appending(path: "readme.md"))
        let rows = try TreeComparer(mode: .nameAndDate, showHidden: false).compare(first.mount, second.mount)
        #expect(rows.count == 2)
    }

    @Test func twoNamesOnOneSideDontBothClaimOneFile() throws {
        let sensitive = try DiskImage(format: "Case-sensitive APFS")
        let ordinary = try DiskImage(format: "APFS")
        try write("x", sensitive.mount.appending(path: "File"))
        try write("x", sensitive.mount.appending(path: "file"))
        try write("x", ordinary.mount.appending(path: "File"))
        let rows = try TreeComparer(mode: .nameAndDate, showHidden: false).compare(ordinary.mount, sensitive.mount)
        #expect(rows.count == 2)
        #expect(rows.first { $0.left != nil }?.right?.name == "File")
        // The spare `file` can never land beside `File` on the ordinary volume.
        let spare = try #require(rows.first { $0.left == nil })
        #expect(spare.verdict == .nameTaken)
        #expect(spare.action == .none)
    }

    @Test func exactNamesPairFirstInAnyListingOrder() throws {
        let sensitive = try DiskImage(format: "Case-sensitive APFS")
        let ordinary = try DiskImage(format: "APFS")
        // Enough names that the listing is bound to give some capitals first.
        for name in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            try write("x", sensitive.mount.appending(path: name))
            try write("y", sensitive.mount.appending(path: name.uppercased()))
            try write("x", ordinary.mount.appending(path: name))
        }
        let rows = try TreeComparer(mode: .content, showHidden: false).compare(sensitive.mount, ordinary.mount)
        #expect(rows.count == 16)
        #expect(rows.filter { $0.verdict == .same }.count == 8)
        #expect(rows.filter { $0.verdict == .nameTaken }.count == 8)
    }

    @Test func unicodeFormsAreOneName() throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        try write("x", a.appending(path: "caf\u{E9}"))
        try write("x", b.appending(path: "cafe\u{301}"))
        let rows = try compare(temp)
        #expect(rows.count == 1)
        #expect(rows[0].verdict == .same)
    }

    @Test func fatsTwoSecondDatesArentADifference() throws {
        let fat = try DiskImage(format: "MS-DOS")
        let temp = try TempFolder()
        let source = temp.url.appending(path: "FILE.TXT")
        // An odd second, which FAT can't store.
        try write("x", source, age: 1)
        let target = fat.mount.appending(path: "FILE.TXT")
        _ = try CopyEngine().copy(source, to: target, conflict: .skip)
        let rows = try TreeComparer(mode: .nameAndDate, showHidden: false).compare(temp.url, fat.mount)
        #expect(rows.count == 1)
        #expect(rows[0].verdict == .same)
    }
}

@Suite struct TextDiffTests {
    @Test func linesLineUp() throws {
        let rows = try TextDiff.rows(["a", "b", "c"], ["a", "x", "c", "d"])
        #expect(rows.map(\.left) == ["a", "b", "c", nil])
        #expect(rows.map(\.right) == ["a", "x", "c", "d"])
        #expect(rows.map(\.isChanged) == [false, true, false, true])
    }

    @Test func aRemovedLineLeavesAGap() throws {
        let rows = try TextDiff.rows(["a", "b", "c"], ["a", "c"])
        #expect(rows.map(\.right) == ["a", nil, "c"])
    }

    @Test func emptyFilesDiffToNothing() throws {
        #expect(try TextDiff.rows([], []).isEmpty)
    }

    @Test func aBigFileWithASmallChangeIsQuick() throws {
        var left = (0..<100_000).map { "line \($0)" }
        let right = left
        left[50_000] = "changed"
        let rows = try TextDiff.rows(left, right)
        #expect(rows.count == 100_000)
        #expect(rows.filter(\.isChanged).count == 1)
        #expect(rows[50_000].left == "changed")
        #expect(rows[50_000].right == "line 50000")
    }

    @Test func filesWithNothingInCommonAreRefusedRatherThanGroundThrough() {
        let left = (0..<50_000).map { "a\($0)" }
        let right = (0..<50_000).map { "b\($0)" }
        #expect(throws: TextDiff.Failure.tooDifferent) { _ = try TextDiff.rows(left, right) }
    }

    @Test func repeatedLinesAtTheEndsDontOverlap() throws {
        let rows = try TextDiff.rows(["a", "a"], ["a", "a", "a"])
        #expect(rows.compactMap(\.right).count == 3)
        #expect(rows.compactMap(\.left).count == 2)
    }

    @Test func windowsLineEndingsStillMakeLines() throws {
        let temp = try TempFolder()
        let (one, two) = (temp.url.appending(path: "one"), temp.url.appending(path: "two"))
        try Data("same\r\nleft\r\n".utf8).write(to: one)
        try Data("same\r\nright\r\n".utf8).write(to: two)
        let rows = try TextDiff.rows(one, two)
        #expect(rows.count == 2)
        #expect(rows.count { $0.isChanged } == 1)
    }

    @Test func lineEndingsAloneShowAsADifference() throws {
        let temp = try TempFolder()
        let (one, two) = (temp.url.appending(path: "one"), temp.url.appending(path: "two"))
        try Data("line\r\n".utf8).write(to: one)
        try Data("line\n".utf8).write(to: two)
        #expect(try TextDiff.rows(one, two).count { $0.isChanged } == 1)
    }

    @Test func linksAndPipesAreNeverRead() throws {
        let temp = try TempFolder()
        let huge = temp.url.appending(path: "huge")
        try Data(repeating: 65, count: 3 * 1024 * 1024).write(to: huge)
        let link = temp.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: huge)
        #expect(throws: TextDiff.Failure.notText) { _ = try TextDiff.rows(link, link) }
        let pipe = temp.url.appending(path: "pipe")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: TextDiff.Failure.notText) { _ = try TextDiff.rows(pipe, pipe) }
    }

    @Test func binaryAndHugeFilesAreRefused() throws {
        let temp = try TempFolder()
        let binary = temp.url.appending(path: "bin")
        try Data([0, 1, 2]).write(to: binary)
        #expect(throws: TextDiff.Failure.notText) { _ = try TextDiff.rows(binary, binary) }
        let huge = temp.url.appending(path: "huge")
        try Data(repeating: 65, count: 3 * 1024 * 1024).write(to: huge)
        #expect(throws: TextDiff.Failure.tooLarge) { _ = try TextDiff.rows(huge, huge) }
    }
}

@MainActor
@Suite struct CompareSessionTests {
    private func open(_ temp: TempFolder) async throws -> CompareSession {
        let session = CompareSession(left: temp.url.appending(path: "a"), right: temp.url.appending(path: "b"), showHidden: false)
        await session.finished()
        return session
    }

    private func select(_ session: CompareSession, _ name: String) {
        session.cursor = session.visible.firstIndex { $0.name == name } ?? 0
    }

    private func oneSided(_ temp: TempFolder) throws {
        let a = try temp.folder("a")
        _ = try temp.folder("b")
        try write("x", a.appending(path: "f"))
    }

    @Test func deletionsNeedAllowingFirst() async throws {
        let temp = try TempFolder()
        try oneSided(temp)
        let session = try await open(temp)
        session.choose(.trash)
        #expect(session.toTrash == 0)
        #expect(session.notice == "Press A to allow deletions first. Nothing is deleted by default.")
        session.setAllowsDeletions(true)
        session.choose(.trash)
        #expect(session.toTrash == 1)
    }

    @Test func aFileOnBothSidesCanNeverBeTrashed() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        try write("new", a.appending(path: "f"), age: 10)
        try write("old", b.appending(path: "f"))
        let session = try await open(temp)
        session.setAllowsDeletions(true)
        session.choose(.trash)
        #expect(session.toTrash == 0)
        #expect(session.notice == "X only trashes a file that exists on one side. Use the arrows to replace one copy.")
    }

    @Test func turningDeletionsOffTakesThemBack() async throws {
        let temp = try TempFolder()
        try oneSided(temp)
        let session = try await open(temp)
        session.setAllowsDeletions(true)
        session.choose(.trash)
        session.setAllowsDeletions(false)
        #expect(session.toTrash == 0)
        #expect(session.preview.items.isEmpty)
    }

    @Test func directionsNeedSomethingToCopy() async throws {
        let temp = try TempFolder()
        try oneSided(temp)
        let session = try await open(temp)
        session.choose(.toLeft)
        #expect(session.notice == "That side has nothing to copy.")
        #expect(session.toRight == 1)
    }

    @Test func pressingTheSameDirectionTurnsItOff() async throws {
        let temp = try TempFolder()
        try oneSided(temp)
        let session = try await open(temp)
        session.choose(.toRight)
        #expect(session.skipped == 1)
        #expect(!session.canSync)
    }

    @Test func differencesHideMatchingRowsAndEmptyFolders() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        try temp.folder("a/same")
        try temp.folder("b/same")
        try write("x", a.appending(path: "same/f"))
        try write("x", b.appending(path: "same/f"))
        try temp.folder("a/changed")
        try temp.folder("b/changed")
        try temp.folder("a/changed/deep")
        try temp.folder("b/changed/deep")
        try write("x", a.appending(path: "changed/deep/new"))
        let session = try await open(temp)
        session.onlyDifferences = true
        #expect(session.visible.map(\.name) == ["changed", "deep", "new"])
    }

    @Test func aModeChangeComparesAgain() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        try write("abc", a.appending(path: "f"), age: 100)
        try write("xyz", b.appending(path: "f"))
        let session = try await open(temp)
        #expect(session.itemCount == 1)
        session.mode = .size
        await session.finished()
        #expect(session.itemCount == 0)
    }

    @Test func anUnreadableOrTakenRowCantBeGivenADirection() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        let locked = a.appending(path: "f")
        try write("abc", locked)
        try write("xyz", b.appending(path: "f"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let session = CompareSession(left: a, right: b, showHidden: false)
        await session.finished()
        session.mode = .content
        await session.finished()
        session.choose(.toLeft)
        #expect(session.toLeft == 0)
        #expect(session.notice == "This file couldn't be read, so it wasn't compared.")
    }

    @Test func aFolderOnOneSideCountsWhatItHolds() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        _ = try temp.folder("b")
        _ = try temp.folder("a/only/deep")
        try write(String(repeating: "x", count: 1000), a.appending(path: "only/one"))
        try write(String(repeating: "x", count: 500), a.appending(path: "only/deep/two"))
        let session = try await open(temp)
        #expect(session.bytes == 1500)
    }

    @Test func aFailedRecompareLeavesNothingToRun() async throws {
        let temp = try TempFolder()
        try oneSided(temp)
        let session = try await open(temp)
        #expect(session.canSync)
        try FileManager.default.removeItem(at: temp.url.appending(path: "b"))
        session.mode = .size
        await session.finished()
        #expect(session.failure != nil)
        #expect(!session.canSync)
        #expect(session.rows.isEmpty)
        #expect(session.preview.items.isEmpty)
    }

    @Test func thePlanIsWhatTheRowsSay() async throws {
        let temp = try TempFolder()
        let a = try temp.folder("a")
        let b = try temp.folder("b")
        try write("new", a.appending(path: "f"), age: 10)
        try write("old", b.appending(path: "f"))
        try write("x", b.appending(path: "g"))
        let session = try await open(temp)
        select(session, "g")
        session.setAllowsDeletions(true)
        session.choose(.trash)
        let items = session.preview.items
        #expect(items.count == 2)
        #expect(items.first { $0.source.name == "f" }?.existing != nil)
        #expect(items.first { $0.source.name == "g" }?.target == nil)
    }
}

@MainActor
@Suite struct SyncTests {
    private func setup(_ temp: TempFolder) async throws -> Workspace {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        return app
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func aSyncMakesBothSidesMatchAndComparesAgain() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let (a, b) = (temp.url.appending(path: "a"), temp.url.appending(path: "b"))
        try write("newer", a.appending(path: "f"), age: 10)
        try write("older", b.appending(path: "f"))
        try write("only", a.appending(path: "left"))
        try write("right", b.appending(path: "right"))
        try temp.folder("a/tree")
        try write("in tree", a.appending(path: "tree/inner"))
        app.beginCompare()
        let session = try #require(app.compareSession)
        await session.finished()
        #expect(session.itemCount == 4)
        app.runSync()
        await app.jobs.finished()
        await session.finished()
        #expect(try text(b.appending(path: "f")) == "newer")
        #expect(try text(b.appending(path: "left")) == "only")
        #expect(try text(a.appending(path: "right")) == "right")
        #expect(try text(b.appending(path: "tree/inner")) == "in tree")
        #expect(session.itemCount == 0)
        #expect(app.compareSession != nil)
    }

    @Test func skippedRowsStaySkippedAfterASync() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let (a, b) = (temp.url.appending(path: "a"), temp.url.appending(path: "b"))
        try write("newer", a.appending(path: "keep"), age: 10)
        try write("older", b.appending(path: "keep"))
        try write("only", a.appending(path: "other"))
        app.beginCompare()
        let session = try #require(app.compareSession)
        await session.finished()
        session.cursor = session.visible.firstIndex { $0.name == "keep" } ?? 0
        session.choose(.skip)
        app.runSync()
        await app.jobs.finished()
        await session.finished()
        #expect(session.toRight == 0)
        #expect(session.skipped == 1)
        #expect(!session.canSync)
        #expect(try text(b.appending(path: "keep")) == "older")
    }

    @Test func aFileChangedAfterComparingIsLeftAlone() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let (a, b) = (temp.url.appending(path: "a"), temp.url.appending(path: "b"))
        try write("newer", a.appending(path: "f"), age: 10)
        try write("older", b.appending(path: "f"))
        app.beginCompare()
        let session = try #require(app.compareSession)
        await session.finished()
        // Someone saves over the copy that was about to be replaced.
        try write("edited since", b.appending(path: "f"), age: 500)
        app.runSync()
        await app.jobs.finished()
        #expect(try text(b.appending(path: "f")) == "edited since")
        #expect(app.report?.failures.first?.reason == "It changed after the comparison, so it was left alone.")
    }

    /// Chooses Trash for `name`, ready to run.
    private func chooseTrash(_ app: Workspace, _ name: String) async throws {
        app.beginCompare()
        let session = try #require(app.compareSession)
        await session.finished()
        session.setAllowsDeletions(true)
        session.cursor = try #require(session.visible.firstIndex { $0.name == name })
        session.choose(.trash)
        #expect(session.toTrash == 1)
    }

    @Test func aFolderThatGainedAFileIsNotTrashed() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let folder = try temp.folder("a/only")
        try await chooseTrash(app, "only")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: folder.path)
        app.runSync()
        await app.jobs.finished()
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(app.report?.failures.first?.reason == "It changed after the comparison, so it was left alone.")
    }

    @Test func aFileSwappedForAFolderIsNotTrashed() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let file = temp.url.appending(path: "a/f")
        try write("x", file)
        try await chooseTrash(app, "f")
        try FileManager.default.removeItem(at: file)
        _ = try temp.folder("a/f")
        app.runSync()
        await app.jobs.finished()
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(app.report?.failures.first?.reason == "It changed after the comparison, so it was left alone.")
    }

    @Test func anUntouchedFolderGoesToTrash() async throws {
        // Off the main actor, because making one blocks and the other tests need that thread.
        let image = try await Task.detached { try DiskImage(format: "APFS") }.value
        let (a, b) = (image.mount.appending(path: "a"), image.mount.appending(path: "b"))
        for folder in [a, b] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let only = a.appending(path: "only")
        try FileManager.default.createDirectory(at: only, withIntermediateDirectories: true)
        let app = Workspace(left: a, right: b)
        for panel in app.panels {
            panel.refresh()
            await panel.loaded()
        }
        try await chooseTrash(app, "only")
        app.runSync()
        await app.jobs.finished()
        #expect(app.report == nil)
        #expect(!FileManager.default.fileExists(atPath: only.path))
    }

    @Test func aFileThatAppearedAfterComparingIsNotOverwritten() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let (a, b) = (temp.url.appending(path: "a"), temp.url.appending(path: "b"))
        try write("mine", a.appending(path: "f"))
        app.beginCompare()
        let session = try #require(app.compareSession)
        await session.finished()
        try write("arrived", b.appending(path: "f"))
        app.runSync()
        await app.jobs.finished()
        #expect(try text(b.appending(path: "f")) == "arrived")
    }

    @Test func aSyncNeedsTheCompareScreen() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.runSync()
        #expect(app.jobs.current == nil)
    }

    @Test func aSyncWaitsForTheComparison() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try write("x", temp.url.appending(path: "a/f"))
        app.beginCompare()
        app.runSync()
        #expect(app.jobs.current == nil)
        await app.compareSession?.finished()
        app.closeCompare()
    }

    @Test func comparingAFolderWithItselfIsRefused() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.panels[1].navigate(to: temp.url.appending(path: "a"))
        await app.panels[1].loaded()
        app.beginCompare()
        #expect(app.compareSession == nil)
        #expect(app.message == "Both show the same folder.")
    }

    @Test func comparingAFolderWithOneInsideItIsRefused() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        let inner = try temp.folder("a/inner")
        app.panels[1].navigate(to: inner)
        await app.panels[1].loaded()
        app.beginCompare()
        #expect(app.compareSession == nil)
    }

    @Test func comparingTheRootWithAnythingIsRefused() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.panels[0].navigate(to: URL(filePath: "/"))
        await app.panels[0].loaded()
        app.beginCompare()
        #expect(app.compareSession == nil)
    }

    @Test func archivesCantBeCompared() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        try Data().write(to: temp.url.appending(path: "b/x.zip"))
        app.panels[1].navigate(to: temp.url.appending(path: "b/x.zip"))
        app.beginCompare()
        #expect(app.compareSession == nil)
        #expect(app.message == OperationRefusal.readOnlyArchive.message)
    }

    @Test func leavingAFolderClosesTheScreen() async throws {
        let temp = try TempFolder()
        let app = try await setup(temp)
        app.beginCompare()
        #expect(app.isTyping)
        app.panels[0].navigate(to: temp.url)
        #expect(app.compareSession == nil)
    }
}
