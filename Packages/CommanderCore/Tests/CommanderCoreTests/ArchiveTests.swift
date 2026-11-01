import CArchive
import Foundation
import Testing
@testable import CommanderCore

/// One made-up entry for a crafted archive. Crafted through libarchive directly, because Commander's
/// own writer can't produce the dishonest paths these tests need.
private enum Item {
    case file(String, String)
    case folder(String)
    case link(String, String)
}

private func craft(_ url: URL, zip: Bool = false, _ items: [Item]) throws {
    let handle = try #require(archive_write_new())
    defer { archive_write_free(handle) }
    if zip { archive_write_set_format_zip(handle) } else { archive_write_set_format_pax_restricted(handle) }
    #expect(archive_write_open_filename(handle, url.path) == ARCHIVE_OK)
    for item in items {
        let entry = try #require(archive_entry_new())
        defer { archive_entry_free(entry) }
        archive_entry_set_perm(entry, 0o644)
        archive_entry_set_mtime(entry, 1_700_000_000, 0)
        switch item {
        case .file(let path, let text):
            archive_entry_set_pathname_utf8(entry, path)
            archive_entry_set_filetype(entry, UInt32(AE_IFREG))
            archive_entry_set_size(entry, Int64(text.utf8.count))
            #expect(archive_write_header(handle, entry) == ARCHIVE_OK)
            _ = archive_write_data(handle, text, text.utf8.count)
        case .folder(let path):
            archive_entry_set_pathname_utf8(entry, path)
            archive_entry_set_filetype(entry, UInt32(AE_IFDIR))
            #expect(archive_write_header(handle, entry) == ARCHIVE_OK)
        case .link(let path, let target):
            archive_entry_set_pathname_utf8(entry, path)
            archive_entry_set_filetype(entry, UInt32(AE_IFLNK))
            archive_entry_set_symlink_utf8(entry, target)
            #expect(archive_write_header(handle, entry) == ARCHIVE_OK)
        }
    }
    archive_write_close(handle)
}

private func bsdtar(_ arguments: [String], in folder: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/bsdtar")
    process.arguments = arguments
    process.currentDirectoryURL = folder
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

/// Everything below `folder`, as sorted relative paths.
private func tree(_ folder: URL) -> [String] {
    (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
}

private let quarantine = "com.apple.quarantine"

private func quarantined(_ url: URL) -> String? {
    var bytes = [UInt8](repeating: 0, count: 64)
    let size = getxattr(url.path, quarantine, &bytes, 64, 0, XATTR_NOFOLLOW)
    return size < 0 ? nil : String(decoding: bytes.prefix(size), as: UTF8.self)
}

private func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// A tiny stored RAR 4 file holding `inside.txt`, built by hand because macOS has nothing that writes RAR.
private let rarBase64 = "UmFyIRoHAM+QcwAADQAAAAAAAADhBHQAgCoACgAAAAoAAAADXVXQFwAAX1sUMAoAIAAAAGluc2lkZS50eHRyYXIgd29ya3MKxD17AEAHAA=="

@Suite struct ArchivePathTests {
    @Test func namesThatMeanArchives() {
        for name in ["a.zip", "a.TAR", "a.tar.gz", "a.tgz", "a.7z", "a.rar", "a.gz", "a.tar.xz"] {
            #expect(ArchivePath.isArchiveName(name))
        }
        #expect(!ArchivePath.isArchiveName("notes.txt"))
        #expect(!ArchivePath.isArchiveName(".zip"))
    }

    @Test func stemsDropTheWholeExtension() {
        #expect(ArchivePath.stem("logs.tar.gz") == "logs")
        #expect(ArchivePath.stem("logs.ZIP") == "logs")
        #expect(ArchivePath.stem("hello.txt.gz") == "hello.txt")
    }

    @Test func unsafePathsAreRecognised() {
        #expect(ArchivePath.safe("a/b/c") == ["a", "b", "c"])
        #expect(ArchivePath.safe("./a//b") == ["a", "b"])
        #expect(ArchivePath.safe("../a") == nil)
        #expect(ArchivePath.safe("a/../../b") == nil)
        #expect(ArchivePath.safe("/etc/passwd") == nil)
        #expect(ArchivePath.safe("a..b/c..") == ["a..b", "c.."])
    }

    @Test func splitsAPathRunningThroughAnArchive() throws {
        let temp = try TempFolder()
        let archive = try temp.file("a.zip", bytes: 4)
        let split = ArchivePath.split(archive.appending(path: "x/y.txt"))
        #expect(split?.archive.lastPathComponent == "a.zip")
        #expect(split?.inner == ["x", "y.txt"])
        #expect(ArchivePath.split(archive)?.inner == [])
    }

    @Test func aFolderNamedLikeAnArchiveIsAFolder() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("odd.zip")
        #expect(ArchivePath.split(folder.appending(path: "x")) == nil)
    }
}

@Suite struct ArchiveReadingTests {
    private func sample(_ temp: TempFolder) throws -> URL {
        let folder = try temp.folder("in")
        try temp.folder("in/sub")
        try Data("hello".utf8).write(to: folder.appending(path: "hello.txt"))
        try Data("deep".utf8).write(to: folder.appending(path: "sub/deep.txt"))
        return folder
    }

    private func names(_ archive: URL, _ inner: [String] = []) async throws -> [String] {
        let listing = try await RoutedSource().list(inner.reduce(archive) { $0.appending(path: $1) }, sort: FileSort())
        return listing.entries.map(\.fileName)
    }

    @Test(arguments: [("a.zip", ["--format", "zip"]), ("a.tar", []), ("a.tgz", ["-z"]), ("a.tar.xz", ["-J"]), ("a.tar.bz2", ["-j"]), ("a.7z", ["--format", "7zip"])])
    func opensEveryFormat(name: String, flags: [String]) async throws {
        let temp = try TempFolder()
        let folder = try sample(temp)
        try bsdtar(flags + ["-cf", temp.url.appending(path: name).path, "-C", folder.path, "hello.txt", "sub"], in: temp.url)
        let archive = temp.url.appending(path: name)
        #expect(try await names(archive) == ["sub", "hello.txt"])
        #expect(try await names(archive, ["sub"]) == ["deep.txt"])

        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(try text(out.appending(path: "sub/deep.txt")) == "deep")
    }

    @Test func opensRar() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.rar")
        try #require(Data(base64Encoded: rarBase64)).write(to: archive)
        #expect(try await names(archive) == ["inside.txt"])
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(try text(out.appending(path: "inside.txt")) == "rar works\n")
    }

    @Test func opensASingleCompressedFile() async throws {
        let temp = try TempFolder()
        let plain = try temp.file("log.txt", bytes: 2_000)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = ["-k", plain.path]
        try process.run()
        process.waitUntilExit()
        let archive = temp.url.appending(path: "log.txt.gz")
        #expect(try await names(archive) == ["log.txt"])
        // It comes out as the file itself, not a folder holding it.
        let out = temp.url.appending(path: "out.txt")
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(try Data(contentsOf: out).count == 2_000)
    }

    @Test func foldersNeverListedStillAppear() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("x/y/z.txt", "z")])
        #expect(try await names(archive) == ["x"])
        #expect(try await names(archive, ["x", "y"]) == ["z.txt"])
    }

    @Test func unsafeEntriesAreNotListed() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("../evil", "x"), .file("/abs", "x"), .file("fine", "x")])
        #expect(try await names(archive) == ["fine"])
    }

    @Test func nonASCIINamesSurvive() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.zip")
        try craft(archive, zip: true, [.file("café/naïve 日本.txt", "x")])
        #expect(try await names(archive) == ["café"])
        #expect(try await names(archive, ["café"]) == ["naïve 日本.txt"])
    }

    @Test func aDamagedArchiveListsWhatCameBeforeAndSaysSo() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("first", String(repeating: "a", count: 2_000)), .file("second", String(repeating: "b", count: 20_000))])
        let whole = try Data(contentsOf: archive)
        try whole.prefix(whole.count / 2).write(to: archive)
        let listing = try await RoutedSource().list(archive, sort: FileSort())
        #expect(listing.entries.map(\.fileName).contains("first"))
        #expect(listing.notice == "This archive is damaged, so only part of it is listed.")
    }

    @Test func aHealthyArchiveHasNoNotice() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("first", "a")])
        #expect(try await RoutedSource().list(archive, sort: FileSort()).notice == nil)
    }

    @Test func aCancelledReadIsNotAPartialIndex() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("first", "a"), .file("second", "b")])
        let reading = Task.detached { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            do throws(ArchiveError) {
                _ = try ArchiveIndex(archive)
                return false
            } catch {
                return error == .cancelled
            }
        }
        reading.cancel()
        #expect(await reading.value)
    }

    @Test func aMissingFolderInsideIsNotFound() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("x", "x")])
        await #expect(throws: ListingError.notFound) { _ = try await names(archive, ["nope"]) }
    }

    @Test func aFileThatIsntAnArchiveFailsCleanly() async throws {
        let temp = try TempFolder()
        let fake = temp.url.appending(path: "fake.zip")
        try Data("this is not a zip".utf8).write(to: fake)
        await #expect { _ = try await names(fake) } throws: { error in
            guard case ListingError.other(let message) = error else { return false }
            return message.hasPrefix("This archive can't be read")
        }
    }

    @Test func folderSizesComeFromTheIndex() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("x/one", "12345"), .file("x/y/two", "123")])
        #expect(await RoutedSource().folderSize(archive.appending(path: "x")) == 8)
    }

    @Test func manyEntriesListQuickly() async throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, (0..<20_000).map { .file("d\($0 % 100)/f\($0)", "") })
        let start = ContinuousClock.now
        #expect(try await names(archive).count == 100)
        let first = ContinuousClock.now - start
        let second = ContinuousClock.now
        _ = try await names(archive, ["d5"])
        // No wall-clock limit, because disk image tests running alongside can stall this one for seconds.
        #expect(ContinuousClock.now - second < first)
    }
}

@Suite struct ArchiveSafetyTests {
    /// Unpacks into `box/out`, so anything escaping lands in `box`, where it can be seen.
    private func unpack(_ items: [Item], zip: Bool = false, _ temp: TempFolder) throws -> (out: URL, box: URL, report: EngineReport) {
        let box = try temp.folder("box")
        let archive = temp.url.appending(path: zip ? "evil.zip" : "evil.tar")
        try craft(archive, zip: zip, items)
        let out = box.appending(path: "out", directoryHint: .isDirectory)
        let report = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        return (out, box, report)
    }

    private func escaped(_ box: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: box.path).filter { $0 != "out" }
    }

    @Test(arguments: [false, true])
    func dotDotPathsAreBlocked(zip: Bool) throws {
        let temp = try TempFolder()
        let result = try unpack([.file("../evil", "x"), .file("a/../../evil2", "x"), .file("fine", "ok")], zip: zip, temp)
        #expect(try escaped(result.box).isEmpty)
        #expect(tree(result.out) == ["fine"])
        #expect(result.report.failures.count == 2)
    }

    @Test func absolutePathsAreBlocked() throws {
        let temp = try TempFolder()
        let victim = temp.url.appending(path: "victim")
        let result = try unpack([.file(victim.path, "x"), .file("fine", "ok")], temp)
        #expect(!FileNames.exists(victim))
        #expect(tree(result.out) == ["fine"])
    }

    @Test func writingThroughALinkToOutsideCantHappen() throws {
        let temp = try TempFolder()
        let outside = try temp.folder("outside")
        let result = try unpack([.link("door", outside.path), .file("door/evil", "x")], temp)
        #expect(tree(outside).isEmpty)
        // With the folder made first, the file lands safely inside and the link can't be created over it.
        #expect(try text(result.out.appending(path: "door/evil")) == "x")
        var info = stat()
        #expect(lstat(result.out.appending(path: "door").path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
    }

    @Test func aRelativeLinkOutOfTheFolderIsRemoved() throws {
        let temp = try TempFolder()
        let result = try unpack([.link("door", ".."), .file("door/evil", "x"), .link("deep", "../../x")], temp)
        #expect(try escaped(result.box).isEmpty)
        var info = stat()
        #expect(lstat(result.out.appending(path: "deep").path, &info) != 0)
        #expect(try text(result.out.appending(path: "door/evil")) == "x")
    }

    @Test func aChainOfHarmlessLookingLinksIsCaught() throws {
        let temp = try TempFolder()
        // Each is fine on its own text: `d/x` goes up one, and `y` looks like it stays below d.
        let result = try unpack([.folder("d"), .link("d/x", ".."), .link("y", "d/x/..")], temp)
        var info = stat()
        #expect(lstat(result.out.appending(path: "y").path, &info) != 0)
        #expect(result.report.failures.count == 1)
    }

    @Test func aLinkLoopEndsAndIsRemoved() throws {
        let temp = try TempFolder()
        let result = try unpack([.link("a", "b"), .link("b", "a")], temp)
        var info = stat()
        #expect(lstat(result.out.appending(path: "a").path, &info) != 0)
    }

    @Test func linksThatStayInsideAreKept() throws {
        let temp = try TempFolder()
        let result = try unpack([.file("lib/real", "x"), .link("bin/tool", "../lib/real"), .link("dangling", "nowhere")], temp)
        #expect(result.report.failures.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: result.out.appending(path: "bin/tool").path) == "../lib/real")
        #expect(try text(result.out.appending(path: "bin/tool")) == "x")
    }

    @Test func setuidBitsAreDropped() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        let handle = try #require(archive_write_new())
        archive_write_set_format_pax_restricted(handle)
        archive_write_open_filename(handle, archive.path)
        let entry = try #require(archive_entry_new())
        archive_entry_set_pathname_utf8(entry, "tool")
        archive_entry_set_filetype(entry, UInt32(AE_IFREG))
        archive_entry_set_perm(entry, 0o4755)
        archive_entry_set_size(entry, 0)
        archive_write_header(handle, entry)
        archive_entry_free(entry)
        archive_write_close(handle)
        archive_write_free(handle)
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: out.appending(path: "tool").path)[.posixPermissions] as? Int)
        #expect(mode == 0o755)
    }

    @Test func aTruncatedArchiveKeepsWhatCameBefore() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("first", String(repeating: "a", count: 2_000)), .file("second", String(repeating: "b", count: 20_000))])
        let whole = try Data(contentsOf: archive)
        try whole.prefix(whole.count / 2).write(to: archive)
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        let report = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(!report.failures.isEmpty)
        #expect(tree(out) == ["first"])
    }

    @Test func aCorruptArchiveFailsAndLeavesNothing() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.zip")
        try Data(repeating: 0x41, count: 5_000).write(to: archive)
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        #expect(throws: OperationError.self) { _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip) }
        #expect(!FileNames.exists(out))
        #expect(tree(temp.url) == ["a.zip"])
    }

    @Test func stoppingLeavesNothing() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("one", "x")])
        let extractor = ArchiveExtractor()
        extractor.control.cancel()
        #expect(throws: OperationError.cancelled) {
            _ = try extractor.extract(archive, to: temp.url.appending(path: "out", directoryHint: .isDirectory), conflict: .skip)
        }
        #expect(tree(temp.url) == ["a.tar"])
    }

    @Test func manyItemsComeOutInOneRead() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, (0..<50).map { .file("f\($0)", String(repeating: "x", count: 1_000)) })
        let out = try temp.folder("out")
        let items = (0..<50).map { ArchiveExtractor.Item(inner: ["f\($0)"], target: out.appending(path: "f\($0)"), conflict: .skip) }
        let extractor = ArchiveExtractor()
        let result = try extractor.extract(archive, items: items)
        #expect(result.problems.allSatisfy { $0 == nil })
        #expect(tree(out).count == 50)
        // Bytes count reading, so one pass reads the file once however many items there are.
        let size = try #require(try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(extractor.control.snapshot.bytes <= Int64(size))
    }

    @Test func aProblemWithOneItemDoesntStopTheRest() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("one", "1"), .file("two", "2")])
        let out = try temp.folder("out")
        try Data("mine".utf8).write(to: out.appending(path: "one"))
        let result = try ArchiveExtractor().extract(archive, items: [
            .init(inner: ["one"], target: out.appending(path: "one"), conflict: .skip),
            .init(inner: ["two"], target: out.appending(path: "two"), conflict: .skip),
        ])
        #expect(result.problems[0] == .alreadyExists)
        #expect(result.problems[1] == nil)
        #expect(try text(out.appending(path: "one")) == "mine")
        #expect(try text(out.appending(path: "two")) == "2")
    }

    @Test func progressMovesDuringABigFile() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("big", String(repeating: "x", count: 5_000_000))])
        let extractor = ArchiveExtractor()
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try extractor.extract(archive, to: out, conflict: .skip)
        #expect(extractor.control.snapshot.bytes > 4_000_000)
    }

    @Test func oneFileOrFolderCanBeTakenOut() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("x/one", "1"), .file("x/y/two", "2"), .file("other", "3")])
        let single = temp.url.appending(path: "single")
        _ = try ArchiveExtractor().extract(archive, inner: ["x", "one"], to: single, conflict: .skip)
        #expect(try text(single) == "1")
        let folder = temp.url.appending(path: "folder", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(archive, inner: ["x"], to: folder, conflict: .skip)
        #expect(tree(folder) == ["one", "y", "y/two"])
    }

    @Test func aFileAlreadyThereIsNotReplacedUnlessChosen() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("one", "new")])
        let target = temp.url.appending(path: "one")
        try Data("old".utf8).write(to: target)
        #expect(throws: OperationError.alreadyExists) {
            _ = try ArchiveExtractor().extract(archive, inner: ["one"], to: target, conflict: .skip)
        }
        #expect(try text(target) == "old")
        _ = try ArchiveExtractor().extract(archive, inner: ["one"], to: target, conflict: .replace)
        #expect(try text(target) == "new")
    }

    @Test func aDownloadedArchivePassesOnItsWarning() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.zip")
        try craft(archive, zip: true, [.folder("Demo.app/"), .file("Demo.app/Contents/run", "x"), .link("link", "Demo.app")])
        let mark = "0081;00000000;Safari;"
        #expect(setxattr(archive.path, quarantine, mark, mark.utf8.count, 0, 0) == 0)
        let out = temp.url.appending(path: "out")
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        for path in ["", "Demo.app", "Demo.app/Contents", "Demo.app/Contents/run", "link"] {
            #expect(quarantined(out.appending(path: path)) == mark, "\(path)")
        }
    }

    @Test func replacingAnAppKeepsTheWarningOnItsFolders() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("Pack/Demo.app/Contents/run", "new")])
        #expect(setxattr(archive.path, quarantine, "0081;", 5, 0, 0) == 0)
        let out = try temp.folder("out")
        let old = try temp.file("out/Pack/Demo.app/Contents/run")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        let unrelated = try temp.folder("out/Pack/Other.app")
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .replace)
        #expect(try text(old) == "new")
        #expect(quarantined(out.appending(path: "Pack/Demo.app")) == "0081;")
        #expect(quarantined(old) == "0081;")
        #expect(quarantined(unrelated) == nil)
    }

    @Test func markingStopsAtALinkInTheTarget() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("link/Demo.app/run", "new")])
        #expect(setxattr(archive.path, quarantine, "0081;", 5, 0, 0) == 0)
        let outside = try temp.folder("outside/Demo.app")
        let out = try temp.folder("out")
        try FileManager.default.createSymbolicLink(atPath: out.appending(path: "link").path, withDestinationPath: "../outside")
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .replace)
        #expect(quarantined(outside) == nil)
    }

    @Test func aDriveWithoutAttributesStillGetsTheWarning() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("x/one", "text")])
        #expect(setxattr(archive.path, quarantine, "0081;", 5, 0, 0) == 0)
        let image = try DiskImage(format: "ExFAT")
        let out = image.mount.appending(path: "out")
        let report = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(report.failures.isEmpty)
        #expect(quarantined(out.appending(path: "x/one")) == "0081;")
    }

    @Test func oneFileTakenOutOfADownloadKeepsTheWarning() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("one", "x")])
        #expect(setxattr(archive.path, quarantine, "0081;", 5, 0, 0) == 0)
        let out = temp.url.appending(path: "one")
        _ = try ArchiveExtractor().extract(archive, inner: ["one"], to: out, conflict: .skip)
        #expect(quarantined(out) == "0081;")
    }

    @Test func anArchiveWithNoWarningAddsNone() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("one", "x")])
        let out = temp.url.appending(path: "out")
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(quarantined(out.appending(path: "one")) == nil)
    }

    @Test func aFileChangedSinceThePreviewIsNotReplaced() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("one", "new")])
        let target = temp.url.appending(path: "one")
        try Data("mine".utf8).write(to: target)
        let shown = PlannedItem.Existing(isDirectory: false, age: .older, modified: Date(timeIntervalSince1970: 1_000), size: 3)
        let item = ArchiveExtractor.Item(inner: ["one"], target: target, conflict: .replace, existing: shown)
        let result = try ArchiveExtractor().extract(archive, items: [item])
        #expect(result.problems[0] == .unsupported("It changed after the preview, so it was left alone."))
        #expect(try text(target) == "mine")
    }

    @Test func mergingIntoAFolderKeepsNewerFiles() throws {
        let temp = try TempFolder()
        let archive = temp.url.appending(path: "a.tar")
        try craft(archive, [.file("keep", "from archive"), .file("add", "added")])
        let out = try temp.folder("out")
        let newer = out.appending(path: "keep")
        try Data("mine".utf8).write(to: newer)
        let report = try ArchiveExtractor().extract(archive, to: out, conflict: .replace)
        #expect(report.keptNewer == 1)
        #expect(try text(newer) == "mine")
        #expect(try text(out.appending(path: "add")) == "added")
    }
}

@Suite struct ArchiveWritingTests {
    private func sample(_ temp: TempFolder) throws -> URL {
        let folder = try temp.folder("tree")
        try temp.folder("tree/sub")
        try Data("one".utf8).write(to: folder.appending(path: "one.txt"))
        try Data("hidden".utf8).write(to: folder.appending(path: ".hidden"))
        try Data("deep".utf8).write(to: folder.appending(path: "sub/déep.txt"))
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").path, withDestinationPath: "one.txt")
        return folder
    }

    @Test(arguments: ArchiveFormat.allCases)
    func aRoundTripKeepsEverything(format: ArchiveFormat) throws {
        let temp = try TempFolder()
        let folder = try sample(temp)
        let archive = temp.url.appending(path: "made.\(format.ext)")
        let report = try ArchiveWriter().compress([folder], to: archive, format: format)
        #expect(report.failures.isEmpty)
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(tree(out).contains("tree/.hidden"))
        #expect(try text(out.appending(path: "tree/sub/déep.txt")) == "deep")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appending(path: "tree/link").path) == "one.txt")
    }

    @Test(arguments: ArchiveFormat.allCases)
    func theSystemCanReadWhatsMade(format: ArchiveFormat) throws {
        let temp = try TempFolder()
        let folder = try sample(temp)
        let archive = temp.url.appending(path: "made.\(format.ext)")
        _ = try ArchiveWriter().compress([folder], to: archive, format: format)
        let out = try temp.folder("check")
        try bsdtar(["-xf", archive.path, "-C", out.path], in: temp.url)
        #expect(try text(out.appending(path: "tree/one.txt")) == "one")
    }

    @Test func anExistingFileIsNeverReplaced() throws {
        let temp = try TempFolder()
        let folder = try sample(temp)
        let archive = temp.url.appending(path: "made.zip")
        try Data("mine".utf8).write(to: archive)
        #expect(throws: OperationError.alreadyExists) { _ = try ArchiveWriter().compress([folder], to: archive, format: .zip) }
        #expect(try text(archive) == "mine")
    }

    @Test func stoppingLeavesNoFile() throws {
        let temp = try TempFolder()
        let folder = try sample(temp)
        let writer = ArchiveWriter()
        writer.control.cancel()
        let archive = temp.url.appending(path: "made.zip")
        #expect(throws: OperationError.cancelled) { _ = try writer.compress([folder], to: archive, format: .zip) }
        #expect(!FileNames.exists(archive))
        #expect(!tree(temp.url).contains { $0.hasPrefix(".commander") })
    }

    @Test func anUnreadableFileIsReportedAndTheRestKept() throws {
        let temp = try TempFolder()
        let folder = try sample(temp)
        let locked = folder.appending(path: "locked")
        try Data("x".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let archive = temp.url.appending(path: "made.zip")
        let report = try ArchiveWriter().compress([folder], to: archive, format: .zip)
        #expect(report.failures.count == 1)
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(archive, to: out, conflict: .skip)
        #expect(FileNames.exists(out.appending(path: "tree/one.txt")))
        #expect(!FileNames.exists(out.appending(path: "tree/locked")))
    }

    @Test func aFullDiskLeavesNoFile() throws {
        let image = try DiskImage(format: "APFS", megabytes: 5)
        let temp = try TempFolder()
        let big = temp.url.appending(path: "big")
        var bytes = Data(count: 30_000_000)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try bytes.write(to: big)
        let archive = image.mount.appending(path: "made.zip")
        #expect(throws: OperationError.self) { _ = try ArchiveWriter().compress([big], to: archive, format: .zip) }
        #expect(!FileNames.exists(archive))
    }
}

@MainActor
@Suite struct ArchiveFlowTests {
    private func setup(_ temp: TempFolder) async throws -> (Workspace, Panel, Panel) {
        let app = Workspace(left: try temp.folder("a"), right: try temp.folder("b"))
        for panel in app.panels { await load(panel) }
        return (app, app.panels[0], app.panels[1])
    }

    private func load(_ panel: Panel) async {
        panel.refresh()
        await panel.loaded()
    }

    private func zip(_ temp: TempFolder) async throws -> URL {
        let archive = temp.url.appending(path: "a/bundle.zip")
        try craft(archive, zip: true, [.file("docs/note.txt", "note"), .file("top.txt", "top")])
        return archive
    }

    private func enter(_ left: Panel, _ name: String) async {
        left.setCursor(left.rows.firstIndex { $0.fileName == name } ?? 0)
        left.openCursor()
        await left.loaded()
    }

    @Test func returnOpensAnArchiveAndGoingUpLeavesIt() async throws {
        let temp = try TempFolder()
        let (_, left, _) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        await enter(left, "bundle.zip")
        #expect(left.isInsideArchive)
        #expect(left.rows.map(\.fileName) == ["..", "docs", "top.txt"])
        await enter(left, "docs")
        #expect(left.rows.map(\.fileName) == ["..", "note.txt"])
        left.goUp()
        await left.loaded()
        left.goUp()
        await left.loaded()
        #expect(!left.isInsideArchive)
        #expect(left.cursorEntry?.fileName == "bundle.zip")
    }

    @Test func copyingOutOfAnArchiveExtracts() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        await enter(left, "bundle.zip")
        left.markAll()
        app.begin(.copy)
        await app.planned()
        #expect(app.pending?.preview.kind == .extract)
        #expect(right.rows.contains { $0.fileName == "top.txt" })
        app.runOperation()
        await app.jobs.finished()
        #expect(try text(temp.url.appending(path: "b/docs/note.txt")) == "note")
        #expect(try text(temp.url.appending(path: "b/top.txt")) == "top")
    }

    @Test func extractUnpacksIntoAFolderNamedAfterTheArchive() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        left.setCursor(1)
        app.beginExtract()
        await app.planned()
        #expect(right.rows.first { $0.fileName == "bundle" }?.isDirectory == true)
        #expect(right.rows.first { $0.fileName == "bundle" }?.size == nil)
        #expect(left.previewState(of: left.rows[1]) == nil)
        app.runOperation()
        await app.jobs.finished()
        #expect(try text(temp.url.appending(path: "b/bundle/top.txt")) == "top")
        #expect(app.message == "Extracted 1 item.")
    }

    @Test func extractingOverAFolderKeepsBothByDefault() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        _ = try await zip(temp)
        try temp.folder("b/bundle")
        await load(left)
        await load(right)
        left.setCursor(1)
        app.beginExtract()
        await app.planned()
        #expect(app.pending?.choice == .keepBoth)
        app.runOperation()
        await app.jobs.finished()
        #expect(try text(temp.url.appending(path: "b/bundle 2/top.txt")) == "top")
    }

    @Test func aSingleCompressedFileLandsAsThatFile() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let plain = try temp.file("a/log.txt", bytes: 500)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/gzip")
        process.arguments = [plain.path]
        try process.run()
        process.waitUntilExit()
        await load(left)
        left.setCursor(1)
        app.beginExtract()
        await app.planned()
        #expect(right.rows.first { $0.fileName == "log.txt" }?.isDirectory == false)
        #expect(app.pending?.choice == .replace)
        app.runOperation()
        await app.jobs.finished()
        #expect(try Data(contentsOf: temp.url.appending(path: "b/log.txt")).count == 500)
    }

    @Test func unpackingOverAFileMovesAside() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        _ = try await zip(temp)
        try temp.file("b/bundle")
        await load(left)
        await load(right)
        left.setCursor(1)
        app.beginExtract()
        await app.planned()
        #expect(right.rows.contains { $0.fileName == "bundle 2" })
        app.runOperation()
        await app.jobs.finished()
        #expect(try text(temp.url.appending(path: "b/bundle 2/top.txt")) == "top")
        #expect(app.report == nil)
    }

    @Test func manyMarkedFilesComeOutTogether() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        let archive = temp.url.appending(path: "a/bundle.tar")
        try craft(archive, (0..<30).map { .file("f\($0)", "x") })
        await load(left)
        await enter(left, "bundle.tar")
        left.markAll()
        app.begin(.copy)
        await app.planned()
        app.runOperation()
        await app.jobs.finished()
        #expect(app.message == "Extracted 30 items.")
        #expect(tree(temp.url.appending(path: "b")).count == 30)
    }

    @Test func compressRefusesToBuildInsideWhatItReads() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        let inner = try temp.folder("a/inner")
        await load(left)
        right.navigate(to: inner)
        await right.loaded()
        left.setCursor(1)
        app.beginCompress()
        #expect(app.pending == nil)
        #expect(app.message == OperationRefusal.folderIntoItself.message)
    }

    @Test func compressAndCopyWaitForAnOpenField() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        await load(left)
        left.setCursor(1)
        left.beginRename()
        app.beginCompress()
        app.begin(.copy)
        await app.planned()
        #expect(app.pending == nil)
        left.cancelEdit()
        app.beginPattern(marks: true)
        app.beginCompress()
        #expect(app.pending == nil)
        app.cancelPattern()
    }

    @Test func extractNeedsAnArchive() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/plain.txt")
        await load(left)
        left.setCursor(1)
        app.beginExtract()
        await app.planned()
        #expect(app.pending == nil)
        #expect(app.message == "Move the cursor to an archive, or mark some first.")
    }

    @Test func archivesCantBeChanged() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        await enter(left, "bundle.zip")
        left.setCursor(2)
        let refusal = OperationRefusal.readOnlyArchive.message
        for kind in [OperationKind.move, .trash, .delete] {
            app.begin(kind)
            await app.planned()
            #expect(app.pending == nil)
            #expect(app.message == refusal)
        }
        left.beginNewFolder()
        left.beginRename()
        #expect(left.edit == nil)
        app.beginRename()
        #expect(app.renameSession == nil)
        app.beginCompress()
        #expect(app.pending == nil)

        // And nothing can go in, from either side.
        try temp.file("b/incoming")
        await load(right)
        right.setCursor(1)
        app.activate(1)
        app.begin(.copy)
        await app.planned()
        #expect(app.pending == nil)
        #expect(app.message == refusal)
    }

    @Test func compressMakesANamedArchiveInTheOtherPanel() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one", bytes: 500)
        try temp.file("a/two", bytes: 500)
        await load(left)
        left.markAll()
        app.beginCompress()
        #expect(app.pending?.archive?.name == "a")
        #expect(right.rows.contains { $0.fileName == "a.zip" })
        #expect(left.previewState(of: left.rows[1]) == nil)
        app.updateArchive(ArchiveDraft(name: "bundle", format: .tarGz))
        #expect(right.rows.contains { $0.fileName == "bundle.tar.gz" })
        #expect(!right.rows.contains { $0.fileName == "a.zip" })
        app.runOperation()
        await app.jobs.finished()
        #expect(app.message == "Compressed 2 items.")
        let out = temp.url.appending(path: "out", directoryHint: .isDirectory)
        _ = try ArchiveExtractor().extract(temp.url.appending(path: "b/bundle.tar.gz"), to: out, conflict: .skip)
        #expect(tree(out) == ["one", "two"])
    }

    @Test func closingTheCompressBarHandsFocusBack() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        try temp.file("a/one")
        await load(left)
        left.setCursor(1)
        app.beginCompress()
        var tick = app.focusTick
        app.cancelOperation()
        #expect(app.focusTick == tick + 1)
        app.beginCompress()
        tick = app.focusTick
        app.runOperation()
        #expect(app.focusTick == tick + 1)
        await app.jobs.finished()
    }

    @Test func compressRefusesATakenOrBadName() async throws {
        let temp = try TempFolder()
        let (app, left, right) = try await setup(temp)
        try temp.file("a/one")
        try temp.file("b/one.zip")
        await load(left)
        await load(right)
        left.setCursor(1)
        app.beginCompress()
        #expect(app.pending?.archive?.name == "one 2")
        #expect(app.archiveProblem == nil)
        app.updateArchive(ArchiveDraft(name: "one"))
        #expect(app.archiveProblem == "one.zip already exists there.")
        app.runOperation()
        #expect(app.pending != nil)
        app.updateArchive(ArchiveDraft(name: "a/b"))
        #expect(app.archiveProblem != nil)
        app.updateArchive(ArchiveDraft(name: ""))
        #expect(app.archiveProblem == "Enter a name.")
        app.cancelOperation()
        #expect(!right.rows.contains { $0.fileName == "untitled.zip" })
    }

    @Test func aPanelInAnArchiveStillSaysWhereToRunThings() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        await enter(left, "bundle.zip")
        var opened: URL?
        app.desktop.openTerminal = { opened = $0 }
        app.openTerminal()
        #expect(opened?.lastPathComponent == "a")
    }

    @Test func theViewerExplainsFilesInsideAnArchive() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        await enter(left, "bundle.zip")
        left.setCursor(2)
        app.toggleViewer()
        #expect(app.viewer?.notice == "Copy this file out of the archive to view it.")
    }

    @Test func aFileInsideCanBeOpened() async throws {
        let temp = try TempFolder()
        let (app, left, _) = try await setup(temp)
        _ = try await zip(temp)
        await load(left)
        await enter(left, "bundle.zip")
        left.setCursor(2)
        var opened: URL?
        app.openFile = { opened = $0 }
        left.openCursor()
        for _ in 0..<200 where opened == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try text(try #require(opened)) == "top")
    }
}
