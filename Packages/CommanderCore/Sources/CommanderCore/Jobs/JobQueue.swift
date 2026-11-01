import Darwin
import Foundation
import Observation

/// One running or waiting operation.
@MainActor
@Observable
public final class Job: Identifiable {
    public let id = UUID()
    public let kind: OperationKind
    public let itemCount: Int
    public fileprivate(set) var itemsDone = 0
    public fileprivate(set) var bytesDone: Int64 = 0
    public fileprivate(set) var totalBytes: Int64 = 0
    public fileprivate(set) var currentName = ""

    fileprivate let control = JobControl()
    fileprivate let preview: OperationPreview
    fileprivate let choice: ConflictChoice

    init(preview: OperationPreview, choice: ConflictChoice) {
        kind = preview.kind
        itemCount = preview.runCount(choice)
        self.preview = preview
        self.choice = choice
    }

    public var fraction: Double {
        if totalBytes > 0 { return min(Double(bytesDone) / Double(totalBytes), 1) }
        return itemCount > 0 ? Double(itemsDone) / Double(itemCount) : 0
    }
}

/// How a finished job went.
public struct JobReport: Sendable {
    public var kind: OperationKind
    public var succeeded = 0
    public var skipped = 0
    public var keptNewer = 0
    public var failures: [(name: String, reason: String)] = []
    public var wasStopped = false
    /// What a finished rename did, so it can be undone.
    public var renames: [FileRename] = []
    public var isUndo = false

    /// Anything the user should see and dismiss rather than a passing note.
    public var needsAttention: Bool { !failures.isEmpty || keptNewer > 0 || wasStopped }

    public var summary: String {
        let verb = switch kind {
        case .copy: "Copied"
        case .move: "Moved"
        case .trash: "Moved to Trash:"
        case .delete: "Deleted"
        case .rename: "Renamed"
        case .extract: "Extracted"
        case .compress: "Compressed"
        case .sync: "Synced"
        }
        var text = kind == .rename && succeeded == 0 ? "Nothing was renamed." : "\(verb) \(succeeded) item\(succeeded == 1 ? "" : "s")."
        if wasStopped { text = "Stopped. " + text }
        if skipped > 0 { text += " \(skipped) skipped." }
        if keptNewer > 0 { text += " \(keptNewer) newer file\(keptNewer == 1 ? "" : "s") kept." }
        if let first = failures.first {
            text += " \(failures.count) failed: \(first.name): \(first.reason)"
        }
        return text
    }
}

extension JobReport {
    init(_ result: RenameResult) {
        self.init(kind: .rename)
        renames = result.done
        succeeded = result.done.count
        wasStopped = result.wasStopped
        if let failure = result.failure { failures.append(failure) }
        failures += result.stranded.map { ($0.name, "It's now called \($0.now).") }
    }
}

/// Runs operations one at a time, so a second one waits rather than fighting the first for the disk.
@MainActor
@Observable
public final class JobQueue {
    public private(set) var current: Job?
    public private(set) var waiting: [Job] = []

    @ObservationIgnored public var onFinish: (JobReport) -> Void = { _ in }

    public init() {}

    public func add(_ preview: OperationPreview, choice: ConflictChoice) {
        waiting.append(Job(preview: preview, choice: choice))
        startNext()
    }

    public func stopCurrent() {
        current?.control.cancel()
    }

    public func stopAll() {
        waiting.removeAll()
        stopCurrent()
    }

    /// Waits for everything queued, including any cleanup of a stopped job.
    public func finished() async {
        while current != nil || !waiting.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func startNext() {
        guard current == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        current = job
        let (preview, choice, control) = (job.preview, job.choice, job.control)
        Task {
            let polling = Task {
                while !Task.isCancelled {
                    update(job, control.snapshot)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            let report = await Task.detached(priority: .userInitiated) {
                Self.perform(preview, choice, control)
            }.value
            polling.cancel()
            update(job, control.snapshot)
            current = nil
            onFinish(report)
            startNext()
        }
    }

    private func update(_ job: Job, _ snapshot: JobControl.Snapshot) {
        job.bytesDone = snapshot.bytes
        job.totalBytes = snapshot.total
        job.itemsDone = snapshot.items
        job.currentName = snapshot.name
    }

    private nonisolated static func perform(_ preview: OperationPreview, _ choice: ConflictChoice, _ control: JobControl) -> JobReport {
        if preview.kind == .rename {
            let steps = preview.items.compactMap { item in item.target.map { FileRename(from: item.source.url, to: $0) } }
            var report = JobReport(RenameEngine.run(steps, control: control))
            report.isUndo = preview.isUndo
            return report
        }
        if preview.kind == .compress { return compress(preview, control) }
        if preview.kind == .extract { return extract(preview, choice, control) }
        var report = JobReport(kind: preview.kind)
        let engine = CopyEngine(control: control)
        let sizes = measure(preview, choice, control)
        control.expect(bytes: sizes.values.reduce(0, +))
        var settled: Int64 = 0
        for item in preview.items {
            guard !control.isCancelled else {
                report.wasStopped = true
                break
            }
            let name = item.source.fileName
            control.begin(name)
            do {
                switch preview.kind {
                case .trash:
                    try FileManager.default.trashItem(at: item.source.url, resultingItemURL: nil)
                case .delete:
                    // Removes a link rather than what it points to.
                    try FileManager.default.removeItem(at: item.source.url)
                case .rename, .compress, .extract:
                    break
                case .sync:
                    let result = try sync(item, engine)
                    report.keptNewer += result.keptNewer
                    report.failures += result.failures
                case .copy, .move:
                    guard let target = preview.destination(of: item, choice) else {
                        report.skipped += 1
                        continue
                    }
                    // Only a conflict the preview showed may be replaced, and only as it showed it.
                    let conflict = item.existing == nil ? ConflictChoice.skip : choice
                    let result = preview.kind == .copy
                        ? try engine.copy(item.source.url, to: target, conflict: conflict, expected: item.existing)
                        : try engine.move(item.source.url, to: target, conflict: conflict, expected: item.existing)
                    report.keptNewer += result.keptNewer
                    report.failures += result.failures
                }
                report.succeeded += 1
            } catch OperationError.cancelled {
                report.wasStopped = true
                break
            } catch {
                let reason = (error as? OperationError)?.message ?? error.localizedDescription
                report.failures.append((name, reason))
            }
            settled += sizes[item.source.url] ?? 0
            control.finishItem(settled: settled)
        }
        return report
    }

    /// One row of a sync. No target means it goes to Trash.
    private nonisolated static func sync(_ item: PlannedItem, _ engine: CopyEngine) throws -> EngineReport {
        try FileNames.unchanged(item.source.url, item.source.modified, item.source.size, isFolder: item.source.isDirectory, goesToTrash: item.target == nil)
        guard let target = item.target else {
            try FileManager.default.trashItem(at: item.source.url, resultingItemURL: nil)
            return EngineReport()
        }
        // The preview said what it would replace, so anything else there isn't overwritten.
        return try engine.copy(item.source.url, to: target, conflict: item.existing == nil ? .skip : .replace, expected: item.existing)
    }

    /// Goes through each archive once, however many items are coming out of it.
    private nonisolated static func extract(_ preview: OperationPreview, _ choice: ConflictChoice, _ control: JobControl) -> JobReport {
        var report = JobReport(kind: .extract)
        var groups: [URL: [(name: String, item: ArchiveExtractor.Item)]] = [:]
        for planned in preview.items {
            guard let target = preview.destination(of: planned, choice), let place = ArchivePath.split(planned.source.url) else {
                report.skipped += 1
                continue
            }
            // Only a conflict the preview showed may be replaced.
            let conflict = planned.existing == nil ? ConflictChoice.skip : choice
            groups[place.archive, default: []].append(
                (planned.source.fileName, ArchiveExtractor.Item(inner: place.inner, target: target, conflict: conflict, existing: planned.existing))
            )
        }
        let sizes = groups.keys.map { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        control.expect(bytes: sizes.reduce(0, +))
        var settled: Int64 = 0
        for (index, group) in zip(sizes.indices, groups) {
            guard !control.isCancelled else {
                report.wasStopped = true
                break
            }
            control.begin(group.key.lastPathComponent)
            do throws(OperationError) {
                let result = try ArchiveExtractor(control: control).extract(group.key, items: group.value.map(\.item))
                report.keptNewer += result.report.keptNewer
                report.failures += result.report.failures
                for (entry, problem) in zip(group.value, result.problems) {
                    if let problem {
                        report.failures.append((entry.name, problem.message))
                    } else {
                        report.succeeded += 1
                    }
                }
            } catch .cancelled {
                report.wasStopped = true
                break
            } catch {
                report.failures.append((group.key.lastPathComponent, error.message))
            }
            settled += sizes[index]
            control.finishItem(settled: settled)
        }
        return report
    }

    private nonisolated static func compress(_ preview: OperationPreview, _ control: JobControl) -> JobReport {
        var report = JobReport(kind: .compress)
        guard let target = preview.items.first?.target else { return report }
        let sizes = measure(preview, .replace, control)
        control.expect(bytes: sizes.values.reduce(0, +))
        control.begin(target.lastPathComponent)
        do throws(OperationError) {
            let format = target.lastPathComponent.lowercased().hasSuffix(".zip") ? ArchiveFormat.zip : .tarGz
            let result = try ArchiveWriter(control: control).compress(preview.items.map(\.source.url), to: target, format: format)
            report.succeeded = preview.items.count
            report.failures = result.failures
        } catch .cancelled {
            report.wasStopped = true
        } catch {
            report.failures.append((target.lastPathComponent, error.message))
        }
        return report
    }

    /// The bytes each item that will run has to copy. Trash and delete don't count bytes, so they have none,
    /// and their progress goes by items. Folders are walked here because listings don't size them.
    /// shortcut: Stop waits for the folder being walked. Check `control` inside the walk if that proves slow.
    private nonisolated static func measure(_ preview: OperationPreview, _ choice: ConflictChoice, _ control: JobControl) -> [URL: Int64] {
        var sizes: [URL: Int64] = [:]
        guard [.copy, .move, .compress, .sync].contains(preview.kind) else { return [:] }
        for item in preview.items where (preview.kind == .compress || item.target != nil && preview.destination(of: item, choice) != nil) && !control.isCancelled {
            let isFolder = item.source.isDirectory && !item.source.isSymlink
            sizes[item.source.url] = isFolder ? LocalSource.measure(item.source.url) ?? 0 : item.source.size ?? 0
        }
        return sizes
    }
}
