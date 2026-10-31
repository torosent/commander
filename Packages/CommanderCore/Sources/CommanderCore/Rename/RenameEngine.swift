import Foundation

/// How a batch of renames went. It's all or nothing, so `done` is empty unless everything worked.
public struct RenameResult: Sendable {
    public var done: [FileRename] = []
    public var failure: (name: String, reason: String)?
    public var wasStopped = false
    /// Files a rollback couldn't put back, and what they're called now. Empty unless a second failure hit.
    public var stranded: [(name: String, now: String)] = []
}

public enum RenameEngine {
    /// Moves every file to a temporary name, then every temporary name to its target, so a swap or a
    /// chain never lands on a file that hasn't left yet. Any failure puts everything back.
    /// shortcut: a crash between the two steps leaves files under hidden .commander- names. A journal would recover them.
    public static func run(_ steps: [FileRename], control: JobControl? = nil) -> RenameResult {
        var result = RenameResult()
        var parked: [(step: FileRename, temporary: URL)] = []
        var placed = 0

        func undo() {
            for index in (0..<placed).reversed() {
                move(parked[index].step.to, to: parked[index].temporary, showing: parked[index].step.from, into: &result)
            }
            for entry in parked {
                move(entry.temporary, to: entry.step.from, showing: entry.step.from, into: &result)
            }
        }

        for step in steps {
            if control?.isCancelled == true {
                result.wasStopped = true
                undo()
                return result
            }
            let temporary = step.from.deletingLastPathComponent().appending(path: ".commander-\(UUID().uuidString)")
            do throws(OperationError) {
                try FileNames.rename(step.from, to: temporary)
                parked.append((step, temporary))
            } catch {
                result.failure = (step.from.lastPathComponent, error.message)
                undo()
                return result
            }
        }
        for entry in parked {
            do throws(OperationError) {
                try FileNames.rename(entry.temporary, to: entry.step.to)
                placed += 1
                control?.finishItem(settled: 0)
            } catch {
                result.failure = (entry.step.to.lastPathComponent, error.message)
                undo()
                return result
            }
        }
        result.done = steps
        return result
    }

    private static func move(_ source: URL, to target: URL, showing original: URL, into result: inout RenameResult) {
        do throws(OperationError) {
            try FileNames.rename(source, to: target)
        } catch {
            result.stranded.append((original.lastPathComponent, source.lastPathComponent))
        }
    }
}
