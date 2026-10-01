/// Pending layout changes and the single task that applies them in order.
/// `generation` advances whenever processing is cancelled, so work that
/// outlived a pause or Desktop change can tell it is stale.
@MainActor
final class ChangeQueue<Item> {
    private var items: [Item] = []
    private var task: Task<Void, Never>?
    private(set) var generation = 0

    var isProcessing: Bool { task != nil }
    var count: Int { items.count }
    var first: Item? { items.first }

    func contains(where predicate: (Item) -> Bool) -> Bool { items.contains(where: predicate) }

    func append(_ item: Item) { items.append(item) }

    func removeFirst() -> Item? { items.isEmpty ? nil : items.removeFirst() }

    /// Starts processing unless a task is already draining the queue.
    func startIfIdle(_ process: @escaping @MainActor (Int) async -> Void) {
        guard task == nil else { return }
        generation += 1
        let generation = generation
        task = Task { await process(generation) }
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation && !Task.isCancelled }

    /// Called by the processing task when the queue is drained.
    func finish(generation: Int) -> Bool {
        guard isCurrent(generation) else { return false }
        task = nil
        return true
    }

    /// Drops pending items and invalidates the running task.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        items.removeAll()
    }
}
