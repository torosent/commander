import Darwin
import Foundation

public enum OperationKind: String, Sendable {
    case copy, move, trash, delete, rename, extract, compress
}

public enum ConflictChoice: CaseIterable, Sendable {
    case replace, skip, keepBoth
}

public enum OperationRefusal: Error, Equatable, Sendable {
    case nothingSelected
    case alreadyThere
    case folderIntoItself
    case sharedName(String)
    case fileAndFolder(String)
    case destinationMissing
    case readOnlyArchive

    public var message: String {
        switch self {
        case .nothingSelected: "Move the cursor to a file, or mark some first."
        case .alreadyThere: "Those files are already in that folder."
        case .folderIntoItself: "A folder can't go inside itself."
        case .sharedName(let name): "More than one marked file is named \(name). Handle them one at a time."
        case .fileAndFolder(let name): "\(name) is a file on one side and a folder on the other, so one can't replace the other."
        case .destinationMissing: "The destination folder doesn't exist."
        case .readOnlyArchive: "Archives are read-only. Copy or extract the files instead."
        }
    }
}

/// One thing the operation would do.
public struct PlannedItem: Identifiable, Sendable {
    /// What's already at the destination.
    public struct Existing: Sendable {
        public enum Age: Equatable, Sendable {
            case older, same, newer
        }

        public var isDirectory: Bool
        public var age: Age
        public var isNewer: Bool { age == .newer }
    }

    public let source: FileEntry
    public let target: URL?
    public let existing: Existing?
    /// Where Keep Both puts it, chosen once so the preview and the result can't differ.
    public internal(set) var keepBothTarget: URL?
    /// True when an archive unpacks here as a folder.
    public internal(set) var unpacksArchive = false

    public var id: URL { source.url }
}

/// A complete description of a bulk operation. The panels draw it and the job queue runs it,
/// so what you see before confirming is what happens.
public struct OperationPreview: Sendable {
    public let kind: OperationKind
    public let folder: URL?
    public let items: [PlannedItem]
    /// Items left out because they're already in the destination.
    public let alreadyThere: Int
    /// A rename reversing an earlier one, whose redo is already registered.
    public var isUndo = false

    public var conflicts: [PlannedItem] { items.filter { $0.existing != nil } }

    /// Skip whenever something newer would be overwritten, so that takes a deliberate choice.
    public var defaultChoice: ConflictChoice {
        // Unpacking over a folder of the same name is rarely meant, so it lands beside it.
        if items.contains(where: \.unpacksArchive) { return .keepBoth }
        return conflicts.contains { $0.existing?.isNewer == true } ? .skip : .replace
    }

    /// Where an item ends up under a choice, or nil if it's skipped.
    public func destination(of item: PlannedItem, _ choice: ConflictChoice) -> URL? {
        guard let target = item.target else { return nil }
        guard item.existing != nil else { return target }
        switch choice {
        case .replace: return target
        case .skip: return nil
        case .keepBoth: return item.keepBothTarget
        }
    }

    public func runCount(_ choice: ConflictChoice) -> Int {
        choice == .skip ? items.count - conflicts.count : items.count
    }

    public static func plan(_ kind: OperationKind, sources: [FileEntry], into folder: URL?) throws(OperationRefusal) -> OperationPreview {
        let sources = sources.filter { !$0.isParent }
        guard !sources.isEmpty else { throw .nothingSelected }
        let isInside = sources.contains { ArchivePath.split($0.url)?.inner.isEmpty == false }
        if isInside, kind != .copy, kind != .extract { throw .readOnlyArchive }
        // Copying out of an archive is extracting. The panel's contents aren't real files to hand to the engine.
        let kind = isInside ? OperationKind.extract : kind
        guard kind == .copy || kind == .move || kind == .extract, let folder else {
            return OperationPreview(
                kind: kind, folder: nil,
                items: sources.map { PlannedItem(source: $0, target: nil, existing: nil) },
                alreadyThere: 0
            )
        }
        if ArchivePath.split(folder) != nil { throw .readOnlyArchive }
        guard let destination = FileNames.realPath(folder) else { throw .destinationMissing }
        var items: [PlannedItem] = []
        var names = Set<String>()
        var alreadyThere = 0
        for source in sources {
            let unpacks = kind == .extract && ArchivePath.split(source.url)?.inner.isEmpty == true
            // One compressed file comes out as that file. Anything else comes out as a folder.
            let makesFolder = unpacks && !ArchivePath.isSingleFile(source.fileName)
            // Real paths, so a symlinked route to the same folder is caught too.
            let parent = FileNames.realPath(source.url.deletingLastPathComponent())
            if parent == destination, !unpacks {
                alreadyThere += 1
                continue
            }
            if source.isDirectory, !source.isSymlink, let real = FileNames.realPath(source.url),
               destination == real || destination.hasPrefix(real + "/") {
                throw .folderIntoItself
            }
            let name = unpacks ? ArchivePath.stem(source.fileName) : source.fileName
            guard names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw .sharedName(name)
            }
            var target = folder.appending(path: name)
            var found = existing(at: target, against: source)
            if makesFolder, found?.isDirectory == false {
                // A folder can't replace a file, and the name is only a default, so it moves aside.
                target = FileNames.free(target, avoiding: names)
                names.insert(FileNames.key(target))
                found = nil
            }
            if !makesFolder, let found, found.isDirectory != (source.isDirectory && !source.isSymlink) { throw .fileAndFolder(name) }
            var item = PlannedItem(source: source, target: target, existing: found)
            item.unpacksArchive = makesFolder
            items.append(item)
        }
        guard !items.isEmpty else { throw .alreadyThere }
        for index in items.indices where items[index].existing != nil {
            guard let target = items[index].target else { continue }
            let free = FileNames.free(target, avoiding: names)
            names.insert(FileNames.key(free))
            items[index].keepBothTarget = free
        }
        return OperationPreview(kind: kind, folder: folder, items: items, alreadyThere: alreadyThere)
    }

    /// Packing files into one new archive. Only the first item has a target, because they all end up there.
    static func compress(_ sources: [FileEntry], to archive: URL) -> OperationPreview {
        let items = sources.enumerated().map { index, source in
            PlannedItem(source: source, target: index == 0 ? archive : nil, existing: nil)
        }
        return OperationPreview(kind: .compress, folder: archive.deletingLastPathComponent(), items: items, alreadyThere: 0)
    }

    /// Asks the file system rather than comparing names, so case and Unicode rules are the volume's own.
    private static func existing(at target: URL, against source: FileEntry) -> PlannedItem.Existing? {
        var info = stat()
        guard lstat(target.path, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        let gap = modified.timeIntervalSince(source.modified ?? .distantPast)
        return PlannedItem.Existing(
            isDirectory: info.st_mode & S_IFMT == S_IFDIR,
            age: gap >= 1 ? .newer : gap <= -1 ? .older : .same
        )
    }
}

public enum FileNames {
    /// The path with symlinks resolved, or nil if it doesn't exist.
    static func realPath(_ url: URL) -> String? {
        guard let resolved = Darwin.realpath(url.path, nil) else { return nil }
        defer { Darwin.free(resolved) }
        return String(cString: resolved)
    }

    /// A file's identity within one folder, whichever Unicode form or case the volume stored.
    static func key(_ url: URL) -> String {
        key(name: url.lastPathComponent)
    }

    static func key(name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// The next free name beside `url`: `notes 2.md`, `notes 3.md`, and so on. `taken` holds keys
    /// of names that aren't on disk yet.
    public static func free(_ url: URL, avoiding taken: Set<String> = []) -> URL {
        let folder = url.deletingLastPathComponent()
        let (name, ext) = FileEntry.split(url.lastPathComponent)
        var count = 2
        while true {
            let candidate = "\(name) \(count)" + (ext.isEmpty ? "" : ".\(ext)")
            let next = folder.appending(path: candidate)
            if !exists(next), !taken.contains(key(next)) { return next }
            count += 1
        }
    }

    /// The next free "untitled folder" name.
    static func freeFolder(in folder: URL) -> URL {
        let first = folder.appending(path: "untitled folder", directoryHint: .isDirectory)
        return exists(first) ? free(first) : first
    }

    /// Renames in place. Changing only a name's case is fine, but it never replaces another file.
    public static func rename(_ source: URL, to target: URL) throws(OperationError) {
        var from = stat()
        var to = stat()
        guard lstat(source.path, &from) == 0 else { throw .system(errno) }
        if lstat(target.path, &to) == 0 {
            guard from.st_dev == to.st_dev, from.st_ino == to.st_ino else { throw .alreadyExists }
            guard Darwin.rename(source.path, target.path) == 0 else { throw .system(errno) }
            return
        }
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
        guard errno == ENOTSUP || errno == EINVAL else { throw errno == EEXIST ? .alreadyExists : .system(errno) }
        guard Darwin.rename(source.path, target.path) == 0 else { throw .system(errno) }
    }

    /// What's wrong with a typed name, if anything.
    public static func problem(with name: String) -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter a name." }
        if name.contains("/") || name.contains(":") { return "Names can't contain / or :." }
        if name == "." || name == ".." { return "That name is reserved." }
        if name.utf8.count > 255 { return "That name is too long." }
        return nil
    }
}

/// How a row looks while an operation is previewed.
public enum RowPreview: Equatable, Sendable {
    case incoming
    case replacing(PlannedItem.Existing.Age)
    case merging
    case skipped
    case leaving
}

/// A previewed operation waiting for confirmation.
@MainActor
public struct PendingOperation {
    public let preview: OperationPreview
    /// The panel showing the files, which a drag or the clipboard may not have.
    public let source: Panel?
    public let destination: Panel?
    public var choice: ConflictChoice
    /// The name and format being typed, for a compress.
    public var archive: ArchiveDraft?
}

/// A new archive's name, chosen in the status bar.
public struct ArchiveDraft: Equatable, Sendable {
    public var name: String
    public var format: ArchiveFormat
    public var fileName: String { "\(name).\(format.ext)" }

    public init(name: String, format: ArchiveFormat = .zip) {
        self.name = name
        self.format = format
    }
}

public struct EditState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case newFolder
        case rename(URL)
    }

    public let kind: Kind
    public let text: String
}

public struct EditFailure: Error, Sendable {
    public let message: String
}

public struct FileRename: Sendable {
    public let from: URL
    public let to: URL
}
