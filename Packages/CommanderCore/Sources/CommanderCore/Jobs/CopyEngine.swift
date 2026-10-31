import Darwin
import Foundation
import os

public enum OperationError: Error, Equatable, Sendable {
    case cancelled
    case system(Int32)
    case unsupported(String)
    case wrongType
    case alreadyExists
    case sameFile
    case nameCollision

    public var message: String {
        switch self {
        case .cancelled: "Stopped."
        case .system(let code): String(cString: strerror(code))
        case .unsupported(let what): what
        case .wrongType: "A file and a folder can't replace each other."
        case .alreadyExists: "Something with that name appeared after the preview."
        case .sameFile: "That's the same file."
        case .nameCollision: "Another item already took this name, because this volume treats the two names as one."
        }
    }
}

/// Shared between a running job and whoever watches it.
public final class JobControl: Sendable {
    public struct Snapshot: Sendable {
        public var bytes: Int64 = 0
        /// Zero until the job has measured what it's about to do.
        public var total: Int64 = 0
        public var items = 0
        public var name = ""
    }

    private let state = OSAllocatedUnfairLock(initialState: (cancelled: false, snapshot: Snapshot()))

    public init() {}

    public var isCancelled: Bool { state.withLock(\.cancelled) }
    public var snapshot: Snapshot { state.withLock(\.snapshot) }

    public func cancel() {
        state.withLock { $0.cancelled = true }
    }

    func add(bytes: Int64) {
        state.withLock { $0.snapshot.bytes += bytes }
    }

    func begin(_ name: String) {
        state.withLock { $0.snapshot.name = name }
    }

    func expect(bytes: Int64) {
        state.withLock { $0.snapshot.total = bytes }
    }

    /// `settled` is everything finished so far, for items that move without their bytes being counted.
    func finishItem(settled: Int64) {
        state.withLock {
            $0.snapshot.items += 1
            $0.snapshot.bytes = max($0.snapshot.bytes, settled)
        }
    }
}

/// What a folder merge left alone or couldn't do. Files inside a merge are never overwritten
/// by something older, because the preview can't show them.
public struct EngineReport: Sendable {
    public var failures: [(name: String, reason: String)] = []
    public var keptNewer = 0

    mutating func absorb(_ other: EngineReport) {
        failures += other.failures
        keptNewer += other.keptNewer
    }
}

/// Copies and moves. Nothing here writes directly over an existing file, follows a symlink while
/// walking a folder, or removes a source before its copy is safely in place.
public struct CopyEngine: Sendable {
    public let control: JobControl
    /// Called after each progress update. Tests use it to look at the disk mid-copy.
    var onProgress: (@Sendable () -> Void)?

    public init(control: JobControl = JobControl()) {
        self.control = control
    }

    // MARK: Copy

    /// A file already at `target` is replaced only for `.replace`. With any other choice it's an error,
    /// so a file that appeared after the preview can't be overwritten unseen.
    public func copy(_ source: URL, to target: URL, conflict: ConflictChoice) throws(OperationError) -> EngineReport {
        var info = try status(of: source)
        if try isSameFile(&info, target) { throw .sameFile }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            return try copyFolder(source, to: target, info: info, conflict: conflict)
        case S_IFREG, S_IFLNK:
            let exists = FileNames.exists(target)
            if exists, conflict != .replace { throw .alreadyExists }
            try copyLeaf(source, to: target, replacing: exists, size: Int64(info.st_size))
            return EngineReport()
        default:
            throw .unsupported("Special files can't be copied.")
        }
    }

    private func copyFolder(_ source: URL, to target: URL, info: stat, conflict: ConflictChoice) throws(OperationError) -> EngineReport {
        var existing = stat()
        if lstat(target.path, &existing) == 0 {
            guard existing.st_mode & S_IFMT == S_IFDIR else { throw .wrongType }
            return try fill(target, from: source, conflict: conflict, merging: true)
        }
        // A new folder is built under a hidden name, so stopping leaves nothing half made at the real name.
        let building = temporaryName(beside: target)
        guard mkdir(building.path, info.st_mode & 0o7777 | S_IRWXU) == 0 else { throw .system(errno) }
        do {
            let report = try fill(building, from: source, conflict: conflict, merging: false)
            copyAttributes(from: source, to: building)
            try rename(building, to: target, replacing: false)
            return report
        } catch {
            try? FileManager.default.removeItem(at: building)
            throw error
        }
    }

    /// Copies a folder's contents, carrying on past files that fail so one bad file doesn't lose the rest.
    private func fill(_ folder: URL, from source: URL, conflict: ConflictChoice, merging: Bool) throws(OperationError) -> EngineReport {
        var report = EngineReport()
        var written = Set<ino_t>()
        for name in try names(in: source) {
            guard !control.isCancelled else { throw .cancelled }
            let child = source.appending(path: name)
            let target = folder.appending(path: name)
            do {
                try refuseCollision(at: target, with: written)
                defer { remember(target, in: &written) }
                var info = try status(of: child)
                let kind = info.st_mode & S_IFMT
                if merging, FileNames.exists(target) {
                    var existing = stat()
                    guard lstat(target.path, &existing) == 0 else { throw OperationError.system(errno) }
                    if kind == S_IFDIR {
                        guard existing.st_mode & S_IFMT == S_IFDIR else { throw OperationError.wrongType }
                        report.absorb(try fill(target, from: child, conflict: conflict, merging: true))
                        continue
                    }
                    if try isSameFile(&info, target) { continue }
                    switch conflict {
                    case .skip: continue
                    case .keepBoth:
                        try copyLeaf(child, to: FileNames.free(target), replacing: false, size: Int64(info.st_size))
                    case .replace:
                        guard existing.st_mode & S_IFMT != S_IFDIR else { throw OperationError.wrongType }
                        if isNewer(existing, than: info) {
                            report.keptNewer += 1
                            continue
                        }
                        try copyLeaf(child, to: target, replacing: true, size: Int64(info.st_size))
                    }
                } else {
                    report.absorb(try copy(child, to: target, conflict: conflict))
                }
            } catch OperationError.cancelled {
                throw .cancelled
            } catch {
                report.failures.append((name, (error as? OperationError)?.message ?? error.localizedDescription))
            }
        }
        return report
    }

    private func isNewer(_ a: stat, than b: stat) -> Bool {
        a.st_mtimespec.tv_sec > b.st_mtimespec.tv_sec + 1
    }

    /// Copies one file or symlink to a temporary name beside the target, then renames it into place.
    /// The rename is atomic, so at every moment the target is either the old file or the whole new one.
    private func copyLeaf(_ source: URL, to target: URL, replacing: Bool, size: Int64) throws(OperationError) {
        let temporary = temporaryName(beside: target)
        do {
            try cloneOrCopy(source, to: temporary, size: size)
            if replacing { try flush(temporary) }
            try rename(temporary, to: target, replacing: replacing)
        } catch {
            unlink(temporary.path)
            throw error
        }
    }

    private func cloneOrCopy(_ source: URL, to target: URL, size: Int64) throws(OperationError) {
        final class Progress {
            let control: JobControl
            let onProgress: (@Sendable () -> Void)?
            var reported: Int64 = 0
            var failure: Int32 = 0

            init(control: JobControl, onProgress: (@Sendable () -> Void)?) {
                self.control = control
                self.onProgress = onProgress
            }
        }
        let progress = Progress(control: control, onProgress: onProgress)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        let callback: copyfile_callback_t = { _, stage, state, _, _, context in
            let progress = Unmanaged<Progress>.fromOpaque(context!).takeUnretainedValue()
            // Continuing from an error means retry, which would spin forever on a full disk.
            if stage == COPYFILE_ERR {
                progress.failure = errno
                return COPYFILE_QUIT
            }
            if stage == COPYFILE_PROGRESS {
                var copied: off_t = 0
                copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
                progress.control.add(bytes: Int64(copied) - progress.reported)
                progress.reported = Int64(copied)
                progress.onProgress?()
            }
            return progress.control.isCancelled ? COPYFILE_QUIT : COPYFILE_CONTINUE
        }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(callback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(progress).toOpaque())
        // COPYFILE_CLONE clones where the volume can, and otherwise does a full copy with all metadata.
        // It never follows a symlink at the source. COPYFILE_EXCL refuses a temporary name that's somehow taken.
        let result = withExtendedLifetime(progress) {
            copyfile(source.path, target.path, state, copyfile_flags_t(COPYFILE_CLONE | COPYFILE_EXCL))
        }
        guard result == 0 else {
            let code = progress.failure != 0 ? progress.failure : errno
            throw control.isCancelled ? .cancelled : .system(code)
        }
        // A clone reports no progress, so whatever's left is added at once.
        control.add(bytes: size - progress.reported)
    }

    /// Reaches the disk before the rename, so a power cut can't leave an empty file where a good one was.
    private func flush(_ url: URL) throws(OperationError) {
        let descriptor = open(url.path, O_RDONLY | O_SYMLINK)
        guard descriptor >= 0 else { throw .system(errno) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0, errno != ENOTSUP, errno != EINVAL {
            throw .system(errno)
        }
    }

    private func copyAttributes(from source: URL, to target: URL) {
        copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_STAT | COPYFILE_ACL | COPYFILE_XATTR | COPYFILE_NOFOLLOW))
    }

    // MARK: Move

    /// A source whose copy is in place, or a folder that's been emptied. It goes once the copies are on disk.
    private enum Moved {
        case file(URL, copiedTo: URL)
        case folder(URL)
    }

    /// One disk sync per file makes a big folder ten times slower, so sources wait for a shared one.
    private static let settleBatch = 1024

    public func move(_ source: URL, to target: URL, conflict: ConflictChoice) throws(OperationError) -> EngineReport {
        var moved: [Moved] = []
        do throws(OperationError) {
            var report = try transfer(source, to: target, conflict: conflict, moved: &moved)
            report.absorb(settle(&moved))
            return report
        } catch {
            // A stop mustn't leave finished files on both sides.
            _ = settle(&moved)
            throw error
        }
    }

    private func transfer(_ source: URL, to target: URL, conflict: ConflictChoice, moved: inout [Moved]) throws(OperationError) -> EngineReport {
        var info = try status(of: source)
        if try isSameFile(&info, target) { throw .sameFile }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        let exists = FileNames.exists(target)
        if exists, !isFolder, conflict != .replace { throw .alreadyExists }
        if !(isFolder && exists) {
            do throws(OperationError) {
                try rename(source, to: target, replacing: exists)
                control.add(bytes: Int64(info.st_size))
                return EngineReport()
            } catch .system(EXDEV) {
                // Different volumes: copy, then remove below.
            }
        }
        if isFolder {
            return try moveFolder(source, to: target, info: info, conflict: conflict, moved: &moved)
        }
        try copyLeaf(source, to: target, replacing: exists, size: Int64(info.st_size))
        moved.append(.file(source, copiedTo: target))
        return EngineReport()
    }

    /// Moves piece by piece, so a stop or a failure can't lose a file. Each one exists on one side or the other.
    private func moveFolder(_ source: URL, to target: URL, info: stat, conflict: ConflictChoice, moved: inout [Moved]) throws(OperationError) -> EngineReport {
        var report = EngineReport()
        let created = !FileNames.exists(target)
        if created {
            guard mkdir(target.path, info.st_mode & 0o7777 | S_IRWXU) == 0 else { throw .system(errno) }
        }
        var existing = stat()
        guard lstat(target.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFDIR else { throw .wrongType }
        var written = Set<ino_t>()
        for name in try names(in: source) {
            guard !control.isCancelled else { throw .cancelled }
            let child = source.appending(path: name)
            var childTarget = target.appending(path: name)
            do {
                try refuseCollision(at: childTarget, with: written)
                defer { remember(childTarget, in: &written) }
                var childInfo = try status(of: child)
                var other = stat()
                if lstat(childTarget.path, &other) == 0, childInfo.st_mode & S_IFMT != S_IFDIR {
                    if try isSameFile(&childInfo, childTarget) { continue }
                    switch conflict {
                    case .skip: continue
                    case .keepBoth: childTarget = FileNames.free(childTarget)
                    case .replace:
                        if isNewer(other, than: childInfo) {
                            report.keptNewer += 1
                            continue
                        }
                    }
                }
                report.absorb(try transfer(child, to: childTarget, conflict: conflict, moved: &moved))
                if moved.count >= Self.settleBatch { report.absorb(settle(&moved)) }
            } catch OperationError.cancelled {
                throw .cancelled
            } catch {
                report.failures.append((name, error.message))
            }
        }
        if created { copyAttributes(from: source, to: target) }
        if report.failures.isEmpty, report.keptNewer == 0 { moved.append(.folder(source)) }
        return report
    }

    /// Gets the copies onto the disk, and only then removes their sources. Until that sync, a source
    /// may be the only one that would survive a power cut or a pulled drive.
    private func settle(_ moved: inout [Moved]) -> EngineReport {
        var report = EngineReport()
        let copy = moved.lazy.compactMap { if case .file(_, let target) = $0 { target } else { nil } }.first
        let synced = copy.map { sync_volume_np($0.path, SYNC_VOLUME_FULLSYNC | SYNC_VOLUME_WAIT) == 0 } ?? true
        for item in moved {
            switch item {
            case .folder(let folder):
                // Still holds anything that couldn't move, in which case it stays.
                rmdir(folder.path)
            case .file(let source, let target):
                do throws(OperationError) {
                    if !synced { try flush(target) }
                    try removeMoved(source, copiedTo: target)
                } catch {
                    report.failures.append((source.lastPathComponent, error.message))
                }
            }
        }
        moved = []
        return report
    }

    private func removeMoved(_ source: URL, copiedTo target: URL) throws(OperationError) {
        let original = try status(of: source)
        let copied = try status(of: target)
        guard original.st_mode & S_IFMT == S_IFLNK || original.st_size == copied.st_size else {
            throw .unsupported("The copy doesn't match, so the original was kept.")
        }
        guard unlink(source.path) == 0 else { throw .system(errno) }
    }

    // MARK: Helpers

    /// Names that differ at the source can be one name at the destination, like `A` and `a` arriving on an
    /// ordinary volume. Whatever a folder walk already put at a name is never replaced by the next item.
    private func refuseCollision(at target: URL, with written: Set<ino_t>) throws(OperationError) {
        var info = stat()
        if lstat(target.path, &info) == 0, written.contains(info.st_ino) { throw .nameCollision }
    }

    private func remember(_ target: URL, in written: inout Set<ino_t>) {
        var info = stat()
        if lstat(target.path, &info) == 0 { written.insert(info.st_ino) }
    }

    private func status(of url: URL) throws(OperationError) -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw .system(errno) }
        return info
    }

    private func names(in folder: URL) throws(OperationError) -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            let code = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? Int(EIO)
            throw .system(Int32(code))
        }
    }

    private func isSameFile(_ info: inout stat, _ target: URL) throws(OperationError) -> Bool {
        var other = stat()
        guard lstat(target.path, &other) == 0 else { return false }
        return info.st_dev == other.st_dev && info.st_ino == other.st_ino
    }

    private func temporaryName(beside target: URL) -> URL {
        target.deletingLastPathComponent().appending(path: ".commander-\(UUID().uuidString)")
    }

    /// Without `replacing`, an existing target is an error rather than something to overwrite.
    private func rename(_ source: URL, to target: URL, replacing: Bool) throws(OperationError) {
        if replacing {
            guard Darwin.rename(source.path, target.path) == 0 else { throw .system(errno) }
            return
        }
        if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 { return }
        switch errno {
        case EEXIST: throw .alreadyExists
        case ENOTSUP, EINVAL:
            // Some volumes, like FAT, lack the exclusive rename.
            guard !FileNames.exists(target) else { throw .alreadyExists }
            guard Darwin.rename(source.path, target.path) == 0 else { throw .system(errno) }
        default: throw .system(errno)
        }
    }
}
