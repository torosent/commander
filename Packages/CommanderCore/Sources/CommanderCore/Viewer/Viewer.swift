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
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var openingNotice: Task<Void, Never>?

    public init() {}

    /// Shows the cursor's file. The entry changes when the file does, so a saved file reloads.
    public func follow(_ entry: FileEntry?) {
        if isPinned, entry?.url == followed?.url { return }
        guard entry != followed || (url == nil && notice == nil && opening == nil) else { return }
        followed = entry
        isPinned = false
        guard let entry, !entry.isParent, !entry.isDirectory else {
            return clear(title: entry.map(\.fileName) ?? "Viewer", notice: "Move the cursor to a file to view it.")
        }
        // shortcut: there's nothing on disk to read until it's unpacked. Extract to a temporary file here if this is missed.
        if ArchivePath.split(entry.url)?.inner.isEmpty == false {
            return clear(title: entry.fileName, notice: "Copy this file out of the archive to view it.")
        }
        let (url, name, modified) = (entry.url, entry.fileName, entry.modified)
        // Off the main thread, because a sleeping drive can take seconds to answer. What's on show stays
        // for a moment, as blanking the panel for each file passed would flicker.
        stopOpening()
        openingNotice = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Only over what's there, so a slow reload still keeps the view the user chose.
            self?.title = name
            self?.notice = "Opening…"
        }
        opening = Task { [weak self] in
            // On a GCD thread, because a stuck open would hold one of the few that Swift's tasks share.
            let opened = await withCheckedContinuation { (done: CheckedContinuation<Opened, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { done.resume(returning: Self.open(url)) }
            }
            guard !Task.isCancelled else { return }
            self?.show(url, opened, title: name, modified: modified)
        }
    }

    /// Waits for the file being opened, if there is one.
    public func loaded() async {
        await opening?.value
    }

    /// Shows a file that isn't the cursor's, such as a command's output, until the cursor next moves.
    public func pin(_ url: URL, title: String, cursor: FileEntry?) {
        followed = cursor
        isPinned = true
        // At once, because the caller removes the file's name as soon as this returns.
        show(url, Self.open(url), title: title, modified: nil)
    }

    private typealias Opened = Result<(file: PagedFile, size: Int64, looksBinary: Bool), ViewerError>

    private nonisolated static func open(_ url: URL) -> Opened {
        do throws(ViewerError) {
            let file = try PagedFile(url)
            return .success((file, file.size, file.looksBinary))
        } catch {
            return .failure(error)
        }
    }

    private func show(_ url: URL, _ opened: Opened, title: String, modified: Date?) {
        // Reloading the same file keeps the view the user chose.
        let kept = self.url == url ? mode : nil
        clear(title: title, notice: nil)
        self.url = url
        self.modified = modified
        switch opened {
        case .success(let opened):
            file = opened.file
            if Self.isMedia(url) {
                mode = kept ?? .quickLook
            } else if opened.size == 0 {
                notice = "This file is empty."
            } else {
                mode = kept ?? (opened.looksBinary ? .hex : .text)
            }
        case .failure(let error):
            notice = error == .notDownloaded ? "This file hasn't been downloaded yet." : "This file can't be read."
        }
    }

    private func stopOpening() {
        opening?.cancel()
        openingNotice?.cancel()
        opening = nil
    }

    private func clear(title: String, notice: String?) {
        stopOpening()
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
