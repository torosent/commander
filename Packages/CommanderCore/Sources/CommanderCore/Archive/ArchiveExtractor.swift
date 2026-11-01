import Darwin
import Foundation

/// Unpacks all or part of an archive. Whatever the archive says, nothing lands outside the target.
///
/// Three things make that true. Every path goes through `ArchivePath.safe`. Nothing is written through
/// a symlink, because links are only created after all the files, and files are opened with
/// `O_NOFOLLOW | O_EXCL`. And each link is then walked hop by hop, and removed if it leads out.
/// The work happens in a hidden folder beside the target, so stopping leaves nothing half made,
/// and `CopyEngine` makes the final move, so conflicts follow the same rules as any copy.
public struct ArchiveExtractor: Sendable {
    /// One file or folder to take out. An empty `inner` means the whole archive.
    public struct Item: Sendable {
        public var inner: [String]
        public var target: URL
        public var conflict: ConflictChoice
        /// What the preview showed at `target`, if it showed anything.
        public var existing: PlannedItem.Existing?

        public init(inner: [String] = [], target: URL, conflict: ConflictChoice, existing: PlannedItem.Existing? = nil) {
            self.inner = inner
            self.target = target
            self.conflict = conflict
            self.existing = existing
        }
    }

    public struct Result: Sendable {
        public var report = EngineReport()
        /// Why each item failed, in order, or nil where it worked.
        public var problems: [OperationError?] = []
    }

    public let control: JobControl

    private static let blocked = "Blocked, because its path leads outside the folder."

    public init(control: JobControl = JobControl()) {
        self.control = control
    }

    /// A single item, for when one failure should simply be thrown.
    public func extract(_ archive: URL, inner: [String] = [], to target: URL, conflict: ConflictChoice) throws(OperationError) -> EngineReport {
        let result = try extract(archive, items: [Item(inner: inner, target: target, conflict: conflict)])
        if let problem = result.problems[0] { throw problem }
        return result.report
    }

    /// Takes everything out in one read of the archive, because a tar.gz has to be unpacked from the
    /// start to reach anything, so one read per item would repeat all of that work for each.
    /// All the targets must be in the same folder.
    public func extract(_ archive: URL, items: [Item]) throws(OperationError) -> Result {
        guard let first = items.first else { return Result() }
        let stage = first.target.deletingLastPathComponent().appending(path: ".commander-\(UUID().uuidString)")
        guard mkdir(stage.path, 0o700) == 0 else { throw .system(errno) }
        defer { try? FileManager.default.removeItem(at: stage) }

        var selections = items.enumerated().map { index, item in
            Selection(inner: Self.innerPath(item, in: archive), payload: stage.appending(path: "payload-\(index)"))
        }
        var result = Result()
        result.report = try unpack(archive, into: &selections)
        if !Self.spreadQuarantine(from: archive, to: zip(selections, items).map { ($0.payload, $1.target) }) {
            result.report.failures.append((archive.lastPathComponent, "The download warning couldn't be kept on what came out, so take care opening it."))
        }
        // A private control, because these are renames and progress already went by the archive read.
        let engine = CopyEngine(control: JobControl())
        var moves = CopyEngine.Moves()
        for (item, selection) in zip(items, selections) {
            do throws(OperationError) {
                guard FileNames.exists(selection.payload) else {
                    throw .unsupported(result.report.failures.first?.reason ?? "That item isn't in the archive.")
                }
                result.report.absorb(try engine.transfer(selection.payload, to: item.target, conflict: item.conflict, expected: item.existing, moved: &moves))
                result.problems.append(nil)
            } catch {
                result.problems.append(error)
            }
        }
        result.report.absorb(engine.settle(&moves))
        return result
    }

    /// A downloaded archive's warning passes to everything inside, or macOS won't check an app before
    /// it first opens. Folders get it too, because for an `.app` that's where macOS looks, and so do
    /// folders already at the target, which stay when a merge replaces what's in them.
    /// Returns false if a mark couldn't be written.
    private static func spreadQuarantine(from archive: URL, to places: [(payload: URL, target: URL)]) -> Bool {
        let name = "com.apple.quarantine"
        let size = getxattr(archive.path, name, nil, 0, 0, 0)
        guard size > 0 else { return true }
        var mark = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, name, &mark, size, 0, 0) == size else { return true }
        var isMarked = true
        func apply(to url: URL) {
            if setxattr(url.path, name, mark, size, 0, XATTR_NOFOLLOW) != 0 { isMarked = false }
        }
        /// Marks a folder a merge keeps. False if something else is there, which a merge doesn't go through.
        func applyToKept(_ url: URL) -> Bool {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return true }
            guard info.st_mode & S_IFMT == S_IFDIR else { return false }
            apply(to: url)
            return true
        }
        for (payload, target) in places where FileNames.exists(payload) {
            apply(to: payload)
            // A link in the target could lead anywhere, so nothing is marked beyond one.
            var stopped: String? = applyToKept(target) ? nil : ""
            // The walk stays out of symlinked folders, and each link takes the mark itself.
            guard let walk = FileManager.default.enumerator(atPath: payload.path) else { continue }
            for case let path as String in walk {
                apply(to: payload.appending(path: path))
                if let stopped, path.hasPrefix(stopped) { continue }
                if !applyToKept(target.appending(path: path)) { stopped = path + "/" }
            }
        }
        return isMarked
    }

    /// A single compressed file has one entry, named for the archive, and comes out as that file.
    private static func innerPath(_ item: Item, in archive: URL) -> [String] {
        guard item.inner.isEmpty, ArchivePath.isSingleFile(archive.lastPathComponent) else { return item.inner }
        return [ArchivePath.stem(archive.lastPathComponent)]
    }

    /// Where one selected item is being put together, and the links that wait until the end.
    private struct Selection {
        let inner: [String]
        let payload: URL
        var links: [(parts: [String], target: String)] = []
        var hardLinks: [(parts: [String], source: [String])] = []
    }

    private func unpack(_ archive: URL, into selections: inout [Selection]) throws(OperationError) -> EngineReport {
        var report = EngineReport()
        let reader: ArchiveReader
        do throws(ArchiveError) {
            reader = try ArchiveReader(archive)
        } catch {
            throw .unsupported(error.message)
        }
        var reported: Int64 = 0
        func tick() {
            control.add(bytes: reader.bytesRead - reported)
            reported = reader.bytesRead
        }
        let lookup = Dictionary(selections.enumerated().map { ($1.inner.joined(separator: "/"), $0) }) { first, _ in first }

        /// Which selection an entry falls in, and its path below that selection.
        func place(_ parts: [String]) -> (index: Int, path: [String])? {
            for length in 0...parts.count {
                if let index = lookup[parts.prefix(length).joined(separator: "/")] {
                    return (index, Array(parts.dropFirst(length)))
                }
            }
            return nil
        }

        for selection in selections where selection.inner.isEmpty { try makeFolders(selection.payload) }
        while true {
            guard !control.isCancelled else { throw .cancelled }
            let header: ArchiveReader.Header?
            do throws(ArchiveError) {
                header = try reader.next()
            } catch {
                // A damaged archive still gives up what came before the damage.
                report.failures.append((archive.lastPathComponent, error.message))
                break
            }
            guard let header else { break }
            tick()

            guard let parts = ArchivePath.safe(header.path) else {
                report.failures.append((header.path, Self.blocked))
                continue
            }
            guard let (index, path) = place(parts) else { continue }
            let payload = selections[index].payload
            do throws(OperationError) {
                switch header.kind {
                case .folder:
                    try makeFolders(url(path, in: payload))
                case .file:
                    if header.isEncrypted { throw .unsupported("It's password-protected.") }
                    try write(reader, header, to: url(path, in: payload), tick: tick)
                case .link(let target):
                    selections[index].links.append((path, target))
                case .hardLink(let source):
                    let inner = selections[index].inner
                    guard let from = ArchivePath.safe(source), Array(from.prefix(inner.count)) == inner else {
                        throw .unsupported(Self.blocked)
                    }
                    selections[index].hardLinks.append((path, Array(from.dropFirst(inner.count))))
                case .other:
                    throw .unsupported("Special files aren't extracted.")
                }
            } catch .cancelled {
                throw .cancelled
            } catch {
                report.failures.append((header.path, error.message))
            }
        }
        for selection in selections {
            for link in selection.hardLinks {
                let target = url(link.parts, in: selection.payload)
                if (try? makeFolders(target.deletingLastPathComponent())) == nil
                    || Darwin.link(url(link.source, in: selection.payload).path, target.path) != 0 {
                    report.failures.append((link.parts.joined(separator: "/"), String(cString: strerror(errno))))
                }
            }
            report.absorb(makeLinks(selection.links, in: selection.payload))
        }
        return report
    }

    private func url(_ parts: [String], in payload: URL) -> URL {
        parts.reduce(payload) { $0.appending(path: $1) }
    }

    private func makeFolders(_ url: URL) throws(OperationError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .unsupported("A file and a folder in this archive share a name.")
        }
    }

    private func write(_ reader: ArchiveReader, _ header: ArchiveReader.Header, to target: URL, tick: () -> Void) throws(OperationError) {
        try makeFolders(target.deletingLastPathComponent())
        let file = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw .system(errno) }
        var finished = false
        defer {
            close(file)
            if !finished { unlink(target.path) }
        }
        let control = control
        var written: Int64 = 0
        try reader.readData { (block: UnsafeRawBufferPointer, offset: Int64) throws(OperationError) in
            guard !control.isCancelled else { throw .cancelled }
            tick()
            var done = 0
            while done < block.count {
                let count = pwrite(file, block.baseAddress! + done, block.count - done, off_t(offset) + off_t(done))
                guard count > 0 else { throw .system(errno) }
                done += count
            }
            written = max(written, offset + Int64(block.count))
        }
        // A sparse entry ends in a hole, which no block writes.
        if let size = header.size, size > written { ftruncate(file, off_t(size)) }
        // Permissions without setuid, setgid or sticky, and always readable by the owner.
        fchmod(file, header.permissions & 0o777 | 0o600)
        if let modified = header.modified {
            let seconds = timespec(tv_sec: Int(modified.timeIntervalSince1970), tv_nsec: 0)
            futimens(file, [seconds, seconds])
        }
        finished = true
    }

    /// Runs last, so no entry can ever be written through one of these.
    private func makeLinks(_ links: [(parts: [String], target: String)], in payload: URL) -> EngineReport {
        var report = EngineReport()
        var made: [(parts: [String], url: URL)] = []
        for link in links {
            let name = link.parts.joined(separator: "/")
            let location = url(link.parts, in: payload)
            guard !link.target.hasPrefix("/"), !link.parts.isEmpty || !link.target.contains("..") else {
                report.failures.append((name, Self.blocked))
                continue
            }
            guard (try? makeFolders(location.deletingLastPathComponent())) != nil,
                  symlink(link.target, location.path) == 0 else {
                report.failures.append((name, String(cString: strerror(errno))))
                continue
            }
            made.append((link.parts, location))
        }
        // Only once all exist can a chain of them be followed.
        for link in made where leadsOutside(link.parts, in: payload) {
            unlink(link.url.path)
            report.failures.append((link.parts.joined(separator: "/"), Self.blocked))
        }
        return report
    }

    /// Follows a link hop by hop, as the kernel would, without needing what it points at to exist.
    /// A check of the text alone isn't enough: `d/x -> ..` and `y -> d/x/..` both look fine separately.
    private func leadsOutside(_ parts: [String], in payload: URL) -> Bool {
        var place = Array(parts.dropLast())
        var pending = linkTarget(parts, in: payload)
        var hops = 0
        while !pending.isEmpty {
            let part = pending.removeFirst()
            if part == "." { continue }
            if part == ".." {
                if place.isEmpty { return true }
                place.removeLast()
                continue
            }
            place.append(part)
            let next = url(place, in: payload)
            var info = stat()
            guard lstat(next.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { continue }
            hops += 1
            if hops > 40 { return true }
            let target = linkTarget(place, in: payload)
            place.removeLast()
            pending = target + pending
        }
        return false
    }

    private func linkTarget(_ parts: [String], in payload: URL) -> [String] {
        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url(parts, in: payload).path)) ?? ""
        return target.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}
