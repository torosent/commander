import Foundation
import Testing
@testable import CommanderCore

@Test(arguments: [
    ("notes.md", "notes", "md"),
    ("README", "README", ""),
    (".gitignore", ".gitignore", ""),
    (".env.production", ".env", "production"),
    ("archive.tar.gz", "archive", "tar.gz"),
    ("main.3f9c1e.js", "main.3f9c1e", "js"),
    ("trailing.", "trailing.", ""),
])
func splitsNames(file: String, name: String, ext: String) {
    let entry = FileEntry(url: URL(filePath: "/\(file)"), fileName: file, size: 1, modified: nil, isDirectory: false)
    #expect(entry.name == name)
    #expect(entry.ext == ext)
    #expect(entry.fileName == file)
}

@Test func foldersKeepDotsInTheirName() {
    let entry = FileEntry(url: URL(filePath: "/1.8.2"), fileName: "1.8.2", size: nil, modified: nil, isDirectory: true)
    #expect(entry.name == "1.8.2")
    #expect(entry.ext == "")
}

private func files(_ names: String...) -> [FileEntry] {
    names.map { FileEntry(url: URL(filePath: "/\($0)"), fileName: $0, size: 1, modified: nil, isDirectory: false) }
}

@Test func sortsNaturally() {
    let sorted = FileSort().sorted(files("file10", "file2", "File1"))
    #expect(sorted.map(\.name) == ["File1", "file2", "file10"])
}

@Test func foldersComeFirstInEitherDirection() {
    let folder = FileEntry(url: URL(filePath: "/z"), fileName: "z", size: nil, modified: nil, isDirectory: true)
    let entries = [files("a")[0], folder]
    #expect(FileSort().sorted(entries).first == folder)
    #expect(FileSort(ascending: false).sorted(entries).first == folder)
}

@Test func unicodeFormsSortTogether() {
    let composed = "caf\u{E9}1", decomposed = "cafe\u{301}2"
    let sorted = FileSort().sorted(files(decomposed, "cafe0", composed).map { $0 })
    #expect(sorted.map(\.name).last == decomposed)
}

@Test func sortsBySizeAndBreaksTiesByName() {
    var entries = files("b", "a", "c")
    entries[2].size = 9
    #expect(FileSort(key: .size, ascending: false).sorted(entries).map(\.name) == ["c", "a", "b"])
}

@Test func togglingReversesThenResets() {
    let sort = FileSort().toggled(.name)
    #expect(sort == FileSort(key: .name, ascending: false))
    #expect(sort.toggled(.size) == FileSort(key: .size, ascending: true))
}

@Test func crumbsShortenHomeAndVolumes() {
    let home = URL(filePath: "/Users/you", directoryHint: .isDirectory)
    let inHome = Places.crumbs(for: URL(filePath: "/Users/you/projects/atlas"), home: home)
    #expect(inHome.map(\.title) == ["~", "projects", "atlas"])
    #expect(inHome[1].url.path().hasSuffix("/Users/you/projects/"))
    let volume = Places.crumbs(for: URL(filePath: "/Volumes/Archive T7/releases"), home: home)
    #expect(volume.map(\.title) == ["Archive T7", "releases"])
    #expect(Places.crumbs(for: URL(filePath: "/usr/bin"), home: home).map(\.title) == ["/", "usr", "bin"])
    #expect(Places.crumbs(for: URL(filePath: "/"), home: home).map(\.title) == ["/"])
}
