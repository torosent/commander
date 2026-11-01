import Foundation
import Observation

/// Two tabs picked for comparing, by id because tabs can move while they're listed.
public struct CompareChoice: Equatable, Sendable {
    public var first: UUID
    public var second: UUID

    public init(first: UUID, second: UUID) {
        self.first = first
        self.second = second
    }
}

/// The compare screen, which is also the sync's preview: what runs is exactly what the rows show.
@MainActor
@Observable
public final class CompareSession {
    public let left: URL
    public let right: URL
    public let showHidden: Bool

    public var mode = CompareMode.nameAndDate {
        didSet { if mode != oldValue { reload() } }
    }
    public var onlyDifferences = false {
        didSet { rebuild() }
    }
    public private(set) var allowsDeletions = false
    public private(set) var rows: [CompareRow] = []
    /// The rows on screen, in order. Indexes in `cursor` refer to these.
    public private(set) var visible: [CompareRow] = []
    public var cursor = 0
    public private(set) var isComparing = false
    public private(set) var scanned = 0
    public private(set) var failure: String?
    /// Why the last key did nothing.
    public private(set) var notice: String?

    public private(set) var toRight = 0
    public private(set) var toLeft = 0
    public private(set) var toTrash = 0
    public private(set) var skipped = 0
    public private(set) var bytes: Int64 = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var control = JobControl()

    init(left: URL, right: URL, showHidden: Bool) {
        self.left = left
        self.right = right
        self.showHidden = showHidden
        reload()
    }

    /// Stops the comparison, if one is running.
    func stop() {
        control.cancel()
    }

    /// Waits for the comparison. Used by tests.
    public func finished() async {
        await task?.value
    }

    /// Compares again, because a mode change or a sync means the old rows no longer hold.
    /// After a sync, rows the user skipped stay skipped, so one more Return can't copy them.
    func reload(keepingSkips: Bool = false) {
        let skipped = keepingSkips ? Set(rows.filter { $0.action == .skip && $0.suggested != .skip }.compactMap(\.path)) : []
        control.cancel()
        let control = JobControl()
        self.control = control
        isComparing = true
        scanned = 0
        failure = nil
        notice = nil
        let (left, right, mode, showHidden) = (left, right, mode, showHidden)
        let watching = Task {
            while !Task.isCancelled {
                scanned = control.snapshot.items
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        task = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[CompareRow], OperationError> in
                do throws(OperationError) {
                    return .success(try TreeComparer(mode: mode, showHidden: showHidden, control: control).compare(left, right))
                } catch {
                    return .failure(error)
                }
            }.value
            watching.cancel()
            // A newer comparison has taken over, and its result is the one that counts.
            guard control === self.control else { return }
            isComparing = false
            switch result {
            case .success(var rows):
                for index in rows.indices where rows[index].path.map(skipped.contains) == true {
                    rows[index].action = .skip
                }
                self.rows = rows
                allowsDeletions = false
                if !keepingSkips { cursor = 0 }
                rebuild()
            case .failure(.cancelled):
                break
            case .failure(let error):
                // The old rows no longer describe anything, and a sync can't run from what isn't shown.
                failure = error.message
                rows = []
                rebuild()
            }
        }
    }

    private func rebuild() {
        visible = onlyDifferences ? Self.differences(in: rows) : rows
        cursor = min(cursor, max(visible.count - 1, 0))
        toRight = rows.count { $0.action == .toRight }
        toLeft = rows.count { $0.action == .toLeft }
        toTrash = rows.count { $0.action == .trash }
        skipped = rows.count { $0.action == .skip }
        bytes = rows.reduce(0) { total, row in
            switch row.action {
            case .toRight: total + (row.left?.size ?? 0)
            case .toLeft: total + (row.right?.size ?? 0)
            default: total
            }
        }
    }

    /// Rows with something to do, plus the folders above them. An unchanged folder drops out with its contents.
    private static func differences(in rows: [CompareRow]) -> [CompareRow] {
        var kept: [CompareRow] = []
        // Walking backwards, a folder comes after everything inside it.
        var shallowest: Int?
        for row in rows.reversed() {
            let holdsOne = row.isHeader && shallowest.map { row.depth < $0 } == true
            if row.verdict != .same || holdsOne {
                kept.append(row)
                shallowest = row.depth
            }
        }
        return kept.reversed()
    }

    public var itemCount: Int { toRight + toLeft + toTrash }
    public var canSync: Bool { itemCount > 0 && !isComparing && failure == nil }

    public func moveCursor(by count: Int) {
        cursor = min(max(cursor + count, 0), max(visible.count - 1, 0))
        notice = nil
    }

    /// Sets what the cursor's row does. Pressing the same direction again turns it off.
    public func choose(_ action: SyncAction) {
        guard visible.indices.contains(cursor), let index = rows.firstIndex(where: { $0.id == visible[cursor].id }) else { return }
        let row = rows[index]
        guard !row.isHeader else { return }
        if let refusal = refusal(of: action, for: row) {
            notice = refusal
            return
        }
        notice = nil
        rows[index].action = row.action == action ? (row.suggested == action ? .skip : row.suggested) : action
        rebuild()
    }

    private func refusal(of action: SyncAction, for row: CompareRow) -> String? {
        switch action {
        case _ where row.verdict == .clash: "A file and a folder can't replace each other."
        case _ where row.verdict == .unreadable: "This file couldn't be read, so it wasn't compared."
        case _ where row.verdict == .notDownloaded: "This file hasn't been downloaded yet, so it wasn't compared."
        case .toRight where row.verdict == .nameTaken, .toLeft where row.verdict == .nameTaken:
            "The other side already has this name in a different case."
        case .toRight where row.left == nil, .toLeft where row.right == nil: "That side has nothing to copy."
        case .trash where !allowsDeletions: "Press A to allow deletions first. Nothing is deleted by default."
        case .trash where !row.isOneSided: "X only trashes a file that exists on one side. Use the arrows to replace one copy."
        default: nil
        }
    }

    /// Turning deletions off takes back any already chosen.
    public func setAllowsDeletions(_ allowed: Bool) {
        allowsDeletions = allowed
        notice = nil
        if !allowed {
            for index in rows.indices where rows[index].action == .trash { rows[index].action = .skip }
        }
        rebuild()
    }

    /// The sync as a plan. Each item keeps what was compared, so a file that changed since is refused.
    var preview: OperationPreview {
        var items: [PlannedItem] = []
        for row in rows {
            switch row.action {
            case .toRight:
                if let side = row.left { items.append(Self.item(side, to: row.right, in: row.rightFolder)) }
            case .toLeft:
                if let side = row.right { items.append(Self.item(side, to: row.left, in: row.leftFolder)) }
            case .trash:
                // Only a row with one side can get here, so no file loses its only other copy.
                if let side = row.left ?? row.right, row.isOneSided {
                    items.append(PlannedItem(source: Self.entry(side), target: nil, existing: nil))
                }
            case .skip, .none:
                break
            }
        }
        return OperationPreview(kind: .sync, folder: nil, items: items, alreadyThere: 0)
    }

    private static func item(_ source: CompareSide, to replaced: CompareSide?, in folder: URL) -> PlannedItem {
        let existing = replaced.map {
            PlannedItem.Existing(isDirectory: $0.isFolder, age: .same, modified: $0.modified, size: $0.size)
        }
        return PlannedItem(source: entry(source), target: replaced?.url ?? folder.appending(path: source.name), existing: existing)
    }

    private static func entry(_ side: CompareSide) -> FileEntry {
        FileEntry(url: side.url, fileName: side.name, size: side.size, modified: side.modified, isDirectory: side.isFolder, isSymlink: side.isLink)
    }
}
