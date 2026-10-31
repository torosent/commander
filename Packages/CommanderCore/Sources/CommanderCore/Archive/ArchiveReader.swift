import CArchive
import Darwin
import Foundation

public enum ArchiveError: Error, Equatable, Sendable {
    case unreadable(String)
    case passwordProtected
    case cancelled

    public var message: String {
        switch self {
        case .unreadable(let detail): "This archive can't be read: \(detail)"
        case .passwordProtected: "This archive is password-protected."
        case .cancelled: "Stopped."
        }
    }
}

/// Walks an archive's entries in order. Nothing here trusts the archive: callers get raw paths and
/// must pass them through `ArchivePath.safe` before using them.
final class ArchiveReader {
    enum Kind: Equatable {
        case file, folder, other
        case link(String)
        case hardLink(String)
    }

    struct Header {
        let path: String
        let kind: Kind
        let size: Int64?
        let modified: Date?
        let permissions: UInt16
        let isEncrypted: Bool
    }

    private let handle: OpaquePointer
    private let singleName: String?

    init(_ url: URL) throws(ArchiveError) {
        guard let handle = archive_read_new() else { throw .unreadable("out of memory") }
        self.handle = handle
        singleName = ArchivePath.isSingleFile(url.lastPathComponent) ? ArchivePath.stem(url.lastPathComponent) : nil
        archive_read_support_filter_all(handle)
        if singleName == nil {
            archive_read_support_format_all(handle)
        } else {
            archive_read_support_format_raw(handle)
        }
        guard archive_read_open_filename(handle, url.path, 64 * 1024) == ARCHIVE_OK else { throw problem() }
    }

    deinit {
        archive_read_free(handle)
    }

    private func problem() -> ArchiveError {
        let text = archive_error_string(handle).map { String(cString: $0) } ?? "unknown error"
        return text.lowercased().contains("passphrase") || text.lowercased().contains("encrypted")
            ? .passwordProtected : .unreadable(text)
    }

    /// How far through the file reading has got, for progress.
    var bytesRead: Int64 { archive_filter_bytes(handle, -1) }

    func next() throws(ArchiveError) -> Header? {
        var entry: OpaquePointer?
        var status = archive_read_next_header(handle, &entry)
        while status == ARCHIVE_RETRY { status = archive_read_next_header(handle, &entry) }
        if status == ARCHIVE_EOF { return nil }
        guard status == ARCHIVE_OK || status == ARCHIVE_WARN, let entry else { throw problem() }

        let type = Int32(archive_entry_filetype(entry))
        let kind: Kind
        if let hardLink = archive_entry_hardlink(entry) {
            kind = .hardLink(Self.text(hardLink))
        } else if type == AE_IFREG || type == 0 {
            // Old tools leave the type out. It's written as a plain file, so this can't make anything special.
            kind = .file
        } else if type == AE_IFDIR {
            kind = .folder
        } else if type == AE_IFLNK {
            kind = .link(Self.text(archive_entry_symlink_utf8(entry) ?? archive_entry_symlink(entry)))
        } else {
            kind = .other
        }
        let time = archive_entry_mtime(entry)
        return Header(
            path: singleName ?? Self.text(archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)),
            kind: kind,
            size: archive_entry_size_is_set(entry) != 0 ? archive_entry_size(entry) : nil,
            modified: time > 0 ? Date(timeIntervalSince1970: TimeInterval(time)) : nil,
            permissions: UInt16(archive_entry_perm(entry)),
            isEncrypted: archive_entry_is_encrypted(entry) != 0
        )
    }

    /// Repairs names that aren't valid UTF-8, which old archives often have.
    private static func text(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    /// Passes the current entry's data along a block at a time, with each block's place in the file.
    func readData(_ write: (UnsafeRawBufferPointer, Int64) throws(OperationError) -> Void) throws(OperationError) {
        while true {
            var block: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            let status = archive_read_data_block(handle, &block, &size, &offset)
            if status == ARCHIVE_EOF { return }
            if status == ARCHIVE_RETRY { continue }
            guard status == ARCHIVE_OK || status == ARCHIVE_WARN else {
                throw .unsupported(problem().message)
            }
            if size > 0 { try write(UnsafeRawBufferPointer(start: block, count: size), offset) }
        }
    }
}
