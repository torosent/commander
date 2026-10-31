import CArchive
import Darwin
import Foundation

public enum ArchiveFormat: String, CaseIterable, Identifiable, Sendable {
    case zip, tarGz

    public var id: Self { self }
    public var ext: String { self == .zip ? "zip" : "tar.gz" }
    public var title: String { self == .zip ? "ZIP" : "TAR.GZ" }
}

/// Makes a new archive. It's built under a hidden name and renamed at the end, so a stop or a failure
/// leaves nothing at the real name, and an existing file is never replaced.
public struct ArchiveWriter: Sendable {
    public let control: JobControl

    public init(control: JobControl = JobControl()) {
        self.control = control
    }

    /// Links are stored as links, and folders keep their contents, hidden files included.
    /// Extended attributes and resource forks aren't stored, because neither format holds them portably.
    public func compress(_ sources: [URL], to target: URL, format: ArchiveFormat) throws(OperationError) -> EngineReport {
        guard !FileNames.exists(target) else { throw .alreadyExists }
        guard let handle = archive_write_new() else { throw .unsupported("Out of memory.") }
        let temporary = target.deletingLastPathComponent().appending(path: ".commander-\(UUID().uuidString)")
        var finished = false
        defer {
            archive_write_free(handle)
            if !finished { unlink(temporary.path) }
        }
        if format == .zip {
            archive_write_set_format_zip(handle)
        } else {
            archive_write_set_format_pax_restricted(handle)
            archive_write_add_filter_gzip(handle)
        }
        guard archive_write_open_filename(handle, temporary.path) == ARCHIVE_OK else { throw .system(errno) }

        var report = EngineReport()
        for source in sources {
            try add(source, as: source.lastPathComponent, to: handle, report: &report)
        }
        guard archive_write_close(handle) == ARCHIVE_OK else {
            throw .unsupported(archive_error_string(handle).map { String(cString: $0) } ?? "The archive couldn't be finished.")
        }
        try FileNames.rename(temporary, to: target)
        finished = true
        return report
    }

    private func add(_ source: URL, as name: String, to handle: OpaquePointer, report: inout EngineReport) throws(OperationError) {
        guard !control.isCancelled else { throw .cancelled }
        var info = stat()
        guard lstat(source.path, &info) == 0 else {
            report.failures.append((name, String(cString: strerror(errno))))
            return
        }
        guard let entry = archive_entry_new() else { throw .unsupported("Out of memory.") }
        defer { archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_perm(entry, info.st_mode & 0o777)
        archive_entry_set_mtime(entry, info.st_mtimespec.tv_sec, 0)

        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            archive_entry_set_filetype(entry, UInt32(AE_IFDIR))
            try writeHeader(entry, to: handle)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: source.path)
            } catch {
                report.failures.append((name, "This folder can't be read."))
                return
            }
            for child in names.sorted() {
                try add(source.appending(path: child), as: "\(name)/\(child)", to: handle, report: &report)
            }
        case S_IFLNK:
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: source.path) else {
                report.failures.append((name, "This link can't be read."))
                return
            }
            archive_entry_set_filetype(entry, UInt32(AE_IFLNK))
            archive_entry_set_symlink_utf8(entry, target)
            try writeHeader(entry, to: handle)
        case S_IFREG:
            // Opened before the header goes in, so an unreadable file leaves no empty entry.
            let file = open(source.path, O_RDONLY | O_NOFOLLOW)
            guard file >= 0 else {
                report.failures.append((name, String(cString: strerror(errno))))
                return
            }
            defer { close(file) }
            archive_entry_set_filetype(entry, UInt32(AE_IFREG))
            archive_entry_set_size(entry, info.st_size)
            try writeHeader(entry, to: handle)
            try copyData(from: file, to: handle)
        default:
            report.failures.append((name, "Special files aren't stored."))
        }
    }

    private func writeHeader(_ entry: OpaquePointer, to handle: OpaquePointer) throws(OperationError) {
        let status = archive_write_header(handle, entry)
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
            throw .unsupported(archive_error_string(handle).map { String(cString: $0) } ?? "The archive couldn't be written.")
        }
    }

    private func copyData(from file: Int32, to handle: OpaquePointer) throws(OperationError) {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        while true {
            guard !control.isCancelled else { throw .cancelled }
            let count = read(file, &buffer, buffer.count)
            guard count >= 0 else { throw .system(errno) }
            if count == 0 { return }
            guard archive_write_data(handle, buffer, count) >= 0 else {
                throw .unsupported(archive_error_string(handle).map { String(cString: $0) } ?? "The archive couldn't be written.")
            }
            control.add(bytes: Int64(count))
        }
    }
}
