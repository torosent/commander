/// Work wanted newest first, one at a time, each key once however many are waiting on it.
/// Only the oldest fall off the end, past `limit`, and whoever wanted them has to ask again.
public struct NewestFirstQueue<Waiter> {
    private let limit: Int
    private var waiting: [(key: String, waiters: [Waiter])] = []
    private var running: (key: String, waiters: [Waiter])?

    public init(limit: Int) {
        self.limit = limit
    }

    public mutating func add(_ key: String, _ waiter: Waiter) {
        if running?.key == key {
            running?.waiters.append(waiter)
        } else if let index = waiting.firstIndex(where: { $0.key == key }) {
            var item = waiting.remove(at: index)
            item.waiters.append(waiter)
            waiting.append(item)
        } else {
            waiting.append((key, [waiter]))
            if waiting.count > limit { waiting.removeFirst(waiting.count - limit) }
        }
    }

    /// The next key and the first waiter on it, unless one is already running.
    public mutating func start() -> (key: String, waiter: Waiter)? {
        guard running == nil, let next = waiting.popLast(), let first = next.waiters.first else { return nil }
        running = next
        return (next.key, first)
    }

    /// Everyone waiting on the one that was running, including any who joined while it ran.
    public mutating func finish() -> [Waiter] {
        defer { running = nil }
        return running?.waiters ?? []
    }
}
