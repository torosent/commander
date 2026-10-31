import Foundation
import Observation
import UniformTypeIdentifiers

/// What's shown in the panel opposite the active one. It follows the cursor until closed.
@MainActor
@Observable
public final class Viewer {
    public enum Mode: Sendable {
        case text, hex, quickLook
    }

    public private(set) var url: URL?
    public private(set) var title = "Viewer"
    public private(set) var file: PagedFile?
    public private(set) var mode = Mode.text
    public private(set) var notice: String?
    public private(set) var modified: Date?
    @ObservationIgnored private var followed: FileEntry?
    @ObservationIgnored private var isPinned = false

    public init() {}

    /// Shows the cursor's file. The entry changes when the file does, so a saved file reloads.
    public func follow(_ entry: FileEntry?) {
        if isPinned, entry?.url == followed?.url { return }
        guard entry != followed || (url == nil && notice == nil) else { return }
        followed = entry
        isPinned = false
        guard let entry, !entry.isParent, !entry.isDirectory else {
            return clear(title: entry.map(\.fileName) ?? "Viewer", notice: "Move the cursor to a file to view it.")
        }
        load(entry.url, title: entry.fileName, modified: entry.modified)
    }

    /// Shows a file that isn't the cursor's, such as a command's output, until the cursor next moves.
    public func pin(_ url: URL, title: String, cursor: FileEntry?) {
        followed = cursor
        isPinned = true
        load(url, title: title, modified: nil)
    }

    private func load(_ url: URL, title: String, modified: Date?) {
        // Reloading the same file keeps the view the user chose.
        let kept = self.url == url ? mode : nil
        clear(title: title, notice: nil)
        self.url = url
        self.modified = modified
        do throws(ViewerError) {
            let opened = try PagedFile(url)
            file = opened
            if Self.isMedia(url) {
                mode = kept ?? .quickLook
            } else if opened.size == 0 {
                notice = "This file is empty."
            } else {
                mode = kept ?? (opened.looksBinary ? .hex : .text)
            }
        } catch {
            notice = error == .notDownloaded ? "This file hasn't been downloaded yet." : "This file can't be read."
        }
    }

    private func clear(title: String, notice: String?) {
        self.title = title
        self.notice = notice
        url = nil
        file = nil
        modified = nil
        mode = .text
    }

    public func toggleHex() {
        guard let file, file.size > 0 else { return }
        if mode == .hex {
            mode = url.map(Self.isMedia) == true ? .quickLook : .text
        } else {
            mode = .hex
        }
    }

    /// Media is better seen than read, so these go to Quick Look.
    private static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return [UTType.image, .pdf, .audiovisualContent].contains { type.conforms(to: $0) }
    }
}
