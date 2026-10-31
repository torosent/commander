import Foundation
import Testing
@testable import CommanderCore

@Suite struct LocalSourceTests {
    let source = LocalSource()

    @Test func listsFilesFoldersAndFacts() async throws {
        let temp = try TempFolder()
        try temp.file("notes.md", bytes: 42)
        try temp.folder("src")
        let listing = try await source.list(temp.url, sort: FileSort())
        #expect(listing.entries.map(\.fileName) == ["src", "notes.md"])
        #expect(listing.entries[1].size == 42)
        #expect(listing.entries[1].modified != nil)
        #expect(listing.entries[0].size == nil)
        #expect(listing.freeSpace != nil)
    }

    @Test func flagsHiddenFiles() async throws {
        let temp = try TempFolder()
        try temp.file(".secret")
        let entries = try await source.list(temp.url, sort: FileSort()).entries
        #expect(entries[0].isHidden)
    }

    @Test func treatsPackagesAsFiles() async throws {
        let temp = try TempFolder()
        try temp.folder("Tool.app/Contents")
        let entry = try await source.list(temp.url, sort: FileSort()).entries[0]
        #expect(entry.isPackage)
        #expect(!entry.opensAsFolder)
        #expect(entry.ext == "app")
    }

    @Test func linksToFoldersOpenAsFolders() async throws {
        let temp = try TempFolder()
        let folder = try temp.folder("real")
        let link = temp.url.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let entries = try await source.list(temp.url, sort: FileSort()).entries
        let entry = try #require(entries.first { $0.name == "link" })
        #expect(entry.isSymlink)
        #expect(entry.opensAsFolder)
    }

    @Test func brokenLinksAreStillListed() async throws {
        let temp = try TempFolder()
        let link = temp.url.appending(path: "broken")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/no/such/place")
        let entries = try await source.list(temp.url, sort: FileSort()).entries
        #expect(entries.map(\.name) == ["broken"])
        #expect(entries[0].isSymlink)
        #expect(!entries[0].isDirectory)
    }

    @Test func reportsMissingFolders() async throws {
        let temp = try TempFolder()
        await #expect(throws: ListingError.notFound) {
            _ = try await source.list(temp.url.appending(path: "gone"), sort: FileSort())
        }
    }

    @Test func reportsFilesAsNotFolders() async throws {
        let temp = try TempFolder()
        let file = try temp.file("plain")
        await #expect(throws: ListingError.notAFolder) {
            _ = try await source.list(file, sort: FileSort())
        }
    }

    @Test func reportsUnreadableFolders() async throws {
        let temp = try TempFolder()
        let locked = try temp.folder("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        await #expect(throws: ListingError.permissionDenied) {
            _ = try await source.list(locked, sort: FileSort())
        }
    }

    @Test func watchReportsNewFiles() async throws {
        let temp = try TempFolder()
        let changes = AsyncStream<Void>.makeStream()
        let watch = source.watch(temp.url) { _ in changes.continuation.yield() }
        defer { watch?.cancel() }
        try temp.file("new")
        let fired = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in changes.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            changes.continuation.finish()
            return first
        }
        #expect(fired)
    }
}
