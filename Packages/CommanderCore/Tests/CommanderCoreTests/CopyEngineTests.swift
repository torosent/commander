import Darwin
import Foundation
import Testing
@testable import CommanderCore

/// A real mounted volume, for what a single folder can't show: other volumes, file systems and full disks.
final class DiskImage: @unchecked Sendable {
    let mount: URL
    private let image: URL

    init(format: String, megabytes: Int = 20) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "commander-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        image = folder.appending(path: "disk.dmg")
        mount = folder.appending(path: "mnt", directoryHint: .isDirectory)
        try Self.run(["create", "-size", "\(megabytes)m", "-fs", format, "-volname", "T", image.path])
        try Self.run(["attach", image.path, "-mountpoint", mount.path, "-nobrowse", "-quiet"])
    }

    deinit {
        try? Self.run(["detach", mount.path, "-force", "-quiet"])
        try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
    }

    private static func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func read(_ url: URL) throws -> String {
    try String(decoding: Data(contentsOf: url), as: UTF8.self)
}

private func files(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

private func setAttribute(_ name: String, _ value: String, on url: URL) {
    _ = value.withCString { setxattr(url.path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
}

private func attribute(_ name: String, on url: URL) -> String? {
    var buffer = [CChar](repeating: 0, count: 256)
    let size = getxattr(url.path, name, &buffer, 255, 0, XATTR_NOFOLLOW)
    return size < 0 ? nil : String(cString: buffer)
}

private func setDate(_ url: URL, _ date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

@Suite struct CopySafetyTests {
    let engine = CopyEngine()

    @Test func copiesAFile() throws {
        let temp = try TempFolder()
        let source = try temp.file("a", bytes: 100)
        let target = temp.url.appending(path: "b")
        _ = try engine.copy(source, to: target, conflict: .skip)
        #expect(try Data(contentsOf: target).count == 100)
        #expect(engine.control.snapshot.bytes == 100)
    }

    @Test func keepsExtendedAttributesAndResourceForks() throws {
        let temp = try TempFolder()
        let source = try temp.file("a")
        setAttribute("com.commander.test", "kept", on: source)
        setAttribute("com.apple.ResourceFork", "fork", on: source)
        let target = temp.url.appending(path: "b")
        _ = try engine.copy(source, to: target, conflict: .skip)
        #expect(attribute("com.commander.test", on: target) == "kept")
        #expect(attribute("com.apple.ResourceFork", on: target) == "fork")
    }

    @Test func keepsDatesAndPermissions() throws {
        let temp = try TempFolder()
        let source = try temp.file("a")
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        try setDate(source, date)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
        let target = temp.url.appending(path: "b")
        _ = try engine.copy(source, to: target, conflict: .skip)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        #expect(attributes[.modificationDate] as? Date == date)
        #expect(attributes[.posixPermissions] as? Int == 0o640)
    }

    @Test func clonesOnTheSameVolume() throws {
        let temp = try TempFolder()
        let source = try temp.file("a", bytes: 1_000_000)
        let target = temp.url.appending(path: "b")
        _ = try engine.copy(source, to: target, conflict: .skip)
        let values = try target.resourceValues(forKeys: [.mayShareFileContentKey])
        #expect(values.mayShareFileContent == true)
    }

    @Test func symlinksCopyAsLinks() throws {
        let temp = try TempFolder()
        let outside = try temp.folder("outside")
        try temp.file("outside/secret", bytes: 100_000)
        let tree = try temp.folder("tree")
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "link"), withDestinationURL: outside)
        let target = temp.url.appending(path: "copy", directoryHint: .isDirectory)
        _ = try engine.copy(tree, to: target, conflict: .skip)
        let link = target.appending(path: "link")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        #expect(engine.control.snapshot.bytes < 100_000)
    }

    @Test func brokenLinksSurvive() throws {
        let temp = try TempFolder()
        let link = temp.url.appending(path: "broken")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/no/such/place")
        let target = temp.url.appending(path: "copy")
        _ = try engine.copy(link, to: target, conflict: .skip)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == "/no/such/place")
    }

    @Test func refusesToCopyAFileOntoItself() throws {
        let temp = try TempFolder()
        let source = try temp.file("a", bytes: 5)
        #expect(throws: OperationError.sameFile) { _ = try engine.copy(source, to: source, conflict: .replace) }
        #expect(try Data(contentsOf: source).count == 5)
    }

    @Test func overwriteSwapsAtomically() throws {
        let temp = try TempFolder()
        let source = try temp.file("new", bytes: 3_000_000)
        let image = try DiskImage(format: "APFS")
        let target = image.mount.appending(path: "file")
        try write("original", to: target)
        var engine = CopyEngine()
        let seen = Locked(false)
        engine.onProgress = {
            // Mid-copy, the target must still be the complete old file.
            if (try? read(target)) != "original" { seen.set(true) }
        }
        _ = try engine.copy(source, to: target, conflict: .replace)
        #expect(!seen.value)
        #expect(try Data(contentsOf: target).count == 3_000_000)
        #expect(files(in: image.mount).filter { $0.hasPrefix(".commander") }.isEmpty)
    }

    @Test func stoppingMidFileKeepsTheOldFileAndLeavesNoTemp() throws {
        let temp = try TempFolder()
        let source = try temp.file("new", bytes: 8_000_000)
        let image = try DiskImage(format: "APFS")
        let target = image.mount.appending(path: "file")
        try write("original", to: target)
        var engine = CopyEngine()
        let control = engine.control
        engine.onProgress = { control.cancel() }
        #expect(throws: OperationError.cancelled) { _ = try engine.copy(source, to: target, conflict: .replace) }
        #expect(try read(target) == "original")
        #expect(files(in: image.mount).filter { $0.hasPrefix(".commander") }.isEmpty)
    }

    @Test func stoppingAFolderCopyLeavesNothingAtTheName() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        try temp.file("tree/a", bytes: 4_000_000)
        try temp.file("tree/b", bytes: 4_000_000)
        let image = try DiskImage(format: "APFS")
        var engine = CopyEngine()
        let control = engine.control
        engine.onProgress = { control.cancel() }
        let target = image.mount.appending(path: "tree", directoryHint: .isDirectory)
        #expect(throws: OperationError.cancelled) { _ = try engine.copy(tree, to: target, conflict: .skip) }
        #expect(!FileNames.exists(target))
        #expect(files(in: image.mount).filter { $0.hasPrefix(".commander") }.isEmpty)
    }

    @Test func aFullDiskFailsCleanlyAndKeepsTheOldFile() throws {
        let temp = try TempFolder()
        let source = try temp.file("big", bytes: 30_000_000)
        let image = try DiskImage(format: "APFS", megabytes: 12)
        let target = image.mount.appending(path: "file")
        try write("original", to: target)
        #expect(throws: OperationError.system(ENOSPC)) { _ = try engine.copy(source, to: target, conflict: .replace) }
        #expect(try read(target) == "original")
        #expect(files(in: image.mount).filter { $0.hasPrefix(".commander") }.isEmpty)
    }

    @Test func unreadableFilesFailWithoutStoppingTheRest() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        let locked = try temp.file("tree/locked", bytes: 4)
        try temp.file("tree/open", bytes: 4)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let target = temp.url.appending(path: "copy", directoryHint: .isDirectory)
        let report = try engine.copy(tree, to: target, conflict: .skip)
        #expect(report.failures.map(\.name) == ["locked"])
        #expect(files(in: target) == ["open"])
    }

    @Test func readOnlyDestinationFails() throws {
        let temp = try TempFolder()
        let source = try temp.file("a")
        let folder = try temp.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        #expect(throws: OperationError.system(EACCES)) {
            _ = try engine.copy(source, to: folder.appending(path: "a"), conflict: .skip)
        }
    }

    @Test func fileAndFolderCantReplaceEachOther() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("tree")
        let file = try temp.file("plain")
        #expect(throws: OperationError.wrongType) { _ = try engine.copy(folder, to: file, conflict: .replace) }
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func mergeKeepsFilesOnlyInTheDestination() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        try write("from source", to: temp.url.appending(path: "tree/shared"))
        let target = try temp.folder("target")
        try write("older", to: target.appending(path: "shared"))
        try setDate(target.appending(path: "shared"), Date(timeIntervalSince1970: 1_000))
        try write("keep me", to: target.appending(path: "only-here"))
        let report = try engine.copy(tree, to: target, conflict: .replace)
        #expect(report.failures.isEmpty)
        #expect(try read(target.appending(path: "shared")) == "from source")
        #expect(try read(target.appending(path: "only-here")) == "keep me")
    }

    @Test func mergeNeverOverwritesANewerFile() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        let incoming = temp.url.appending(path: "tree/shared")
        try write("older source", to: incoming)
        try setDate(incoming, Date(timeIntervalSince1970: 1_000))
        let target = try temp.folder("target")
        try write("newer", to: target.appending(path: "shared"))
        let report = try engine.copy(tree, to: target, conflict: .replace)
        #expect(report.keptNewer == 1)
        #expect(try read(target.appending(path: "shared")) == "newer")
    }

    @Test func keepBothInAMergeAddsAFile() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        try write("incoming", to: temp.url.appending(path: "tree/note.md"))
        let target = try temp.folder("target")
        try write("existing", to: target.appending(path: "note.md"))
        _ = try engine.copy(tree, to: target, conflict: .keepBoth)
        #expect(try read(target.appending(path: "note.md")) == "existing")
        #expect(try read(target.appending(path: "note 2.md")) == "incoming")
    }

    @Test func aFileThatAppearedAfterThePreviewIsNotOverwritten() throws {
        let temp = try TempFolder()
        let source = try temp.file("a")
        let target = try temp.folder("target")
        let arrived = target.appending(path: "a")
        try write("arrived later", to: arrived)
        #expect(throws: OperationError.alreadyExists) { _ = try engine.copy(source, to: arrived, conflict: .skip) }
        #expect(throws: OperationError.alreadyExists) { _ = try engine.move(source, to: arrived, conflict: .skip) }
        #expect(try read(arrived) == "arrived later")
        #expect(FileNames.exists(source))
    }

    @Test func aTargetThatAppearsIsNotOverwrittenByANewFile() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        try temp.file("tree/a")
        let target = try temp.folder("target")
        try write("arrived later", to: target.appending(path: "a"))
        _ = try engine.copy(tree, to: target, conflict: .skip)
        #expect(try read(target.appending(path: "a")) == "arrived later")
    }
}

@Suite struct MoveSafetyTests {
    let engine = CopyEngine()

    @Test func movesWithinAVolume() throws {
        let temp = try TempFolder()
        let source = try temp.file("a", bytes: 5)
        let target = temp.url.appending(path: "b")
        _ = try engine.move(source, to: target, conflict: .skip)
        #expect(!FileNames.exists(source))
        #expect(FileNames.exists(target))
    }

    @Test func movesAcrossVolumesAndRemovesTheSourceOnlyAfter() throws {
        let temp = try TempFolder()
        let source = try temp.file("a", bytes: 2_000_000)
        setAttribute("com.commander.test", "kept", on: source)
        let image = try DiskImage(format: "APFS")
        let target = image.mount.appending(path: "a")
        var engine = CopyEngine()
        let early = Locked(false)
        engine.onProgress = { if !FileNames.exists(source) { early.set(true) } }
        _ = try engine.move(source, to: target, conflict: .skip)
        #expect(!early.value)
        #expect(!FileNames.exists(source))
        #expect(attribute("com.commander.test", on: target) == "kept")
    }

    @Test func aFailedCrossVolumeMoveKeepsTheSource() throws {
        let temp = try TempFolder()
        let source = try temp.file("big", bytes: 30_000_000)
        let image = try DiskImage(format: "APFS", megabytes: 12)
        #expect(throws: OperationError.system(ENOSPC)) {
            _ = try engine.move(source, to: image.mount.appending(path: "big"), conflict: .skip)
        }
        #expect(FileNames.exists(source))
        #expect(try Data(contentsOf: source).count == 30_000_000)
    }

    @Test func stoppingACrossVolumeMoveKeepsTheSource() throws {
        let temp = try TempFolder()
        let source = try temp.file("big", bytes: 8_000_000)
        let image = try DiskImage(format: "APFS")
        var engine = CopyEngine()
        let control = engine.control
        engine.onProgress = { control.cancel() }
        #expect(throws: OperationError.cancelled) {
            _ = try engine.move(source, to: image.mount.appending(path: "big"), conflict: .skip)
        }
        #expect(try Data(contentsOf: source).count == 8_000_000)
        #expect(files(in: image.mount).filter { $0 == "big" || $0.hasPrefix(".commander") }.isEmpty)
    }

    @Test func movesAFolderAcrossVolumesPieceByPiece() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        try temp.folder("tree/deep")
        try temp.file("tree/deep/a", bytes: 10)
        try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "link").path, withDestinationPath: "deep/a")
        let image = try DiskImage(format: "APFS")
        let target = image.mount.appending(path: "tree", directoryHint: .isDirectory)
        let report = try engine.move(tree, to: target, conflict: .skip)
        #expect(report.failures.isEmpty)
        #expect(!FileNames.exists(tree))
        #expect(try Data(contentsOf: target.appending(path: "deep/a")).count == 10)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appending(path: "link").path) == "deep/a")
    }

    @Test func stoppingAFolderMoveLeavesEachFileOnOneSide() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        for index in 0..<20 { try temp.file("tree/file\(index)", bytes: 200_000) }
        let image = try DiskImage(format: "APFS")
        let target = image.mount.appending(path: "tree", directoryHint: .isDirectory)
        let copies = Locked(0)
        var engine = CopyEngine()
        let control = engine.control
        engine.onProgress = {
            if copies.value == 5 { control.cancel() }
            copies.set(copies.value + 1)
        }
        #expect(throws: OperationError.cancelled) { _ = try engine.move(tree, to: target, conflict: .skip) }
        let left = Set(files(in: tree))
        let arrived = Set(files(in: target))
        #expect(left.isDisjoint(with: arrived))
        #expect(left.union(arrived).count == 20)
        #expect(!arrived.isEmpty)
    }

    @Test func aFolderMoveKeepsWhatItCouldntMove() throws {
        let temp = try TempFolder()
        let tree = try temp.folder("tree")
        try write("older", to: tree.appending(path: "shared"))
        try setDate(tree.appending(path: "shared"), Date(timeIntervalSince1970: 1_000))
        try temp.file("tree/free")
        let target = try temp.folder("target")
        try write("newer", to: target.appending(path: "shared"))
        let report = try engine.move(tree, to: target, conflict: .replace)
        #expect(report.keptNewer == 1)
        #expect(try read(tree.appending(path: "shared")) == "older")
        #expect(FileNames.exists(target.appending(path: "free")))
    }

    @Test func movingKeepsLinksAsLinks() throws {
        let temp = try TempFolder()
        let real = try temp.file("real", bytes: 3)
        let link = temp.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let image = try DiskImage(format: "APFS")
        let target = image.mount.appending(path: "link")
        _ = try engine.move(link, to: target, conflict: .skip)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == real.path)
        #expect(FileNames.exists(real))
    }
}

@Suite struct FileSystemVarietyTests {
    let engine = CopyEngine()

    @Test(arguments: ["HFS+", "Case-sensitive APFS", "MS-DOS"])
    func copiesAndReplacesOn(format: String) throws {
        let temp = try TempFolder()
        let source = try temp.file("file.txt", bytes: 1_000)
        let image = try DiskImage(format: format, megabytes: 40)
        let target = image.mount.appending(path: "file.txt")
        _ = try engine.copy(source, to: target, conflict: .replace)
        _ = try engine.copy(source, to: target, conflict: .replace)
        #expect(try Data(contentsOf: target).count == 1_000)
    }

    @Test func caseOnlyNamesAreSeparateOnCaseSensitiveVolumes() throws {
        let image = try DiskImage(format: "Case-sensitive APFS")
        try write("lower", to: image.mount.appending(path: "name"))
        let temp = try TempFolder()
        let source = try temp.file("NAME", bytes: 1)
        let entry = FileEntry(url: source, fileName: "NAME", size: 1, modified: .now, isDirectory: false)
        let preview = try OperationPreview.plan(.copy, sources: [entry], into: image.mount)
        #expect(preview.conflicts.isEmpty)
    }

    @Test func caseOnlyNamesConflictOnOrdinaryVolumes() throws {
        let image = try DiskImage(format: "APFS")
        try write("lower", to: image.mount.appending(path: "name"))
        let temp = try TempFolder()
        let source = try temp.file("NAME", bytes: 1)
        let entry = FileEntry(url: source, fileName: "NAME", size: 1, modified: .now, isDirectory: false)
        let preview = try OperationPreview.plan(.copy, sources: [entry], into: image.mount)
        #expect(preview.conflicts.count == 1)
    }

    private func collidingFolder(on image: DiskImage) throws -> URL {
        let folder = image.mount.appending(path: "f", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try write("upper", to: folder.appending(path: "A"))
        try write("lower", to: folder.appending(path: "a"))
        return folder
    }

    @Test func namesThatBecomeOneSurviveAMergingMove() throws {
        let source = try DiskImage(format: "Case-sensitive APFS")
        let image = try DiskImage(format: "APFS")
        let folder = try collidingFolder(on: source)
        let target = image.mount.appending(path: "f", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let report = try CopyEngine().move(folder, to: target, conflict: .replace)

        #expect(report.failures.count == 1)
        let arrived = try #require(files(in: target).first)
        let left = try #require(files(in: folder).first)
        #expect(try Set([read(target.appending(path: arrived)), read(folder.appending(path: left))]) == ["upper", "lower"])
    }

    @Test func namesThatBecomeOneAreReportedInAMove() throws {
        let source = try DiskImage(format: "Case-sensitive APFS")
        let image = try DiskImage(format: "APFS")
        let folder = try collidingFolder(on: source)
        let report = try CopyEngine().move(folder, to: image.mount.appending(path: "f", directoryHint: .isDirectory), conflict: .skip)
        #expect(report.failures.count == 1)
        #expect(files(in: folder).count == 1)
    }

    @Test func namesThatBecomeOneAreReportedInACopy() throws {
        let source = try DiskImage(format: "Case-sensitive APFS")
        let image = try DiskImage(format: "APFS")
        let folder = try collidingFolder(on: source)
        let report = try CopyEngine().copy(folder, to: image.mount.appending(path: "f", directoryHint: .isDirectory), conflict: .skip)
        #expect(report.failures.count == 1)
        #expect(files(in: folder).count == 2)
    }
}

@Suite struct PlanningTests {
    private func entry(_ url: URL, isDirectory: Bool = false, modified: Date = .now) -> FileEntry {
        FileEntry(url: url, fileName: url.lastPathComponent, size: 1, modified: modified, isDirectory: isDirectory)
    }

    @Test func refusesItemsAlreadyThere() throws {
        let temp = try TempFolder()
        let file = try temp.file("a")
        #expect(throws: OperationRefusal.alreadyThere) {
            _ = try OperationPreview.plan(.copy, sources: [entry(file)], into: temp.url)
        }
    }

    @Test func seesThroughASymlinkedRouteToTheSameFolder() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("real")
        let file = try temp.file("real/a")
        let alias = temp.url.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        #expect(throws: OperationRefusal.alreadyThere) {
            _ = try OperationPreview.plan(.copy, sources: [entry(file)], into: alias)
        }
    }

    @Test func leavesOutOnlyTheItemsAlreadyThere() throws {
        let temp = try TempFolder()
        let here = try temp.folder("here")
        let local = try temp.file("here/a")
        let other = try temp.file("b")
        let preview = try OperationPreview.plan(.copy, sources: [entry(local), entry(other)], into: here)
        #expect(preview.alreadyThere == 1)
        #expect(preview.items.map(\.source.name) == ["b"])
    }

    @Test func refusesAFolderIntoItself() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("tree")
        let inside = try temp.folder("tree/deep/er")
        #expect(throws: OperationRefusal.folderIntoItself) {
            _ = try OperationPreview.plan(.move, sources: [entry(folder, isDirectory: true)], into: inside)
        }
    }

    @Test func aSimilarlyNamedFolderIsNotInsideIt() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("tree")
        let sibling = try temp.folder("tree2")
        let preview = try OperationPreview.plan(.copy, sources: [entry(folder, isDirectory: true)], into: sibling)
        #expect(preview.items.count == 1)
    }

    @Test func refusesSourcesThatShareAName() throws {
        let temp = try TempFolder()
        let a = try temp.file("one/x".replacingOccurrences(of: "one/", with: ""))
        let folder = try temp.folder("two")
        let b = try temp.file("two/X")
        let target = try temp.folder("target")
        #expect(throws: OperationRefusal.sharedName("X")) {
            _ = try OperationPreview.plan(.copy, sources: [entry(a), entry(b)], into: target)
        }
        _ = folder
    }

    @Test func aNewerDestinationDefaultsToSkip() throws {
        let temp = try TempFolder()
        let source = try temp.file("a")
        let target = try temp.folder("target")
        try temp.file("target/a")
        let old = entry(source, modified: Date(timeIntervalSince1970: 1_000))
        let preview = try OperationPreview.plan(.copy, sources: [old], into: target)
        #expect(preview.defaultChoice == .skip)
        #expect(preview.runCount(.skip) == 0)
    }

    @Test func anOlderDestinationDefaultsToReplace() throws {
        let temp = try TempFolder()
        let source = try temp.file("a")
        let target = try temp.folder("target")
        let existing = try temp.file("target/a")
        try setDate(existing, Date(timeIntervalSince1970: 1_000))
        let preview = try OperationPreview.plan(.copy, sources: [entry(source)], into: target)
        #expect(preview.defaultChoice == .replace)
    }

    @Test func keepBothFindsAFreeName() throws {
        let temp = try TempFolder()
        let source = try temp.file("note.md")
        let target = try temp.folder("target")
        try temp.file("target/note.md")
        try temp.file("target/note 2.md")
        let preview = try OperationPreview.plan(.copy, sources: [entry(source)], into: target)
        let name = preview.destination(of: preview.items[0], .keepBoth)?.lastPathComponent
        #expect(name == "note 3.md")
        #expect(preview.destination(of: preview.items[0], .skip) == nil)
    }

    @Test func keepBothAllowsForOtherItemsInTheBatch() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("to")
        try temp.folder("from")
        try temp.file("to/a")
        let items = [try temp.file("from/a"), try temp.file("from/a 2")].map { entry($0) }
        let preview = try OperationPreview.plan(.copy, sources: items, into: folder)
        #expect(preview.destination(of: preview.items[0], .keepBoth)?.lastPathComponent == "a 3")
        #expect(preview.destination(of: preview.items[1], .keepBoth)?.lastPathComponent == "a 2")
    }

    @Test func refusesAFileAgainstAFolder() throws {
        let temp = try TempFolder()
        let folder = try temp.folder("to")
        try temp.folder("from")
        try temp.folder("to/x")
        try temp.file("to/y")
        let file = entry(try temp.file("from/x"))
        let tree = entry(try temp.folder("from/y"), isDirectory: true)
        #expect(throws: OperationRefusal.fileAndFolder("x")) { try OperationPreview.plan(.copy, sources: [file], into: folder) }
        #expect(throws: OperationRefusal.fileAndFolder("y")) { try OperationPreview.plan(.move, sources: [tree], into: folder) }
    }

    @Test func keepBothKeepsDoubleExtensions() {
        let url = URL(filePath: "/no/such/archive.tar.gz")
        #expect(FileNames.free(url).lastPathComponent == "archive 2.tar.gz")
    }

    @Test(arguments: ["", "  ", "a/b", "a:b", ".", "..", String(repeating: "x", count: 256)])
    func rejectsBadNames(name: String) {
        #expect(FileNames.problem(with: name) != nil)
    }

    @Test func acceptsOrdinaryNames() {
        #expect(FileNames.problem(with: "notes (final).md") == nil)
    }
}

/// A small box for reading a value set inside a progress callback.
final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
