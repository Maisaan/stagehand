import Testing
@testable import Stagehand

/// The queue's generation is how a worker that outlived a pause or Desktop
/// change tells it must stop touching windows.
@MainActor
struct ChangeQueueTests {
    @Test func startingAWorkerAdvancesTheGenerationAndOnlyOneWorkerRuns() async {
        let queue = ChangeQueue<Int>()
        #expect(queue.generation == 0)
        #expect(!queue.isProcessing)
        queue.append(1)
        queue.append(2)
        #expect(queue.count == 2)
        #expect(queue.first == 1)
        #expect(queue.contains { $0 == 2 })

        var started: [Int] = []
        let gate = Gate()
        queue.startIfIdle { generation in
            started.append(generation)
            await gate.wait()
            _ = queue.finish(generation: generation)
        }
        queue.startIfIdle { generation in started.append(generation) }
        #expect(queue.isProcessing)
        #expect(queue.generation == 1)
        #expect(queue.isCurrent(1))
        #expect(!queue.isCurrent(0))

        gate.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while queue.isProcessing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(started == [1])
        #expect(!queue.isProcessing)
        // Items are the worker's to drain; finishing does not clear them.
        #expect(queue.removeFirst() == 1)
        #expect(queue.removeFirst() == 2)
        #expect(queue.removeFirst() == nil)
    }

    @Test func cancelDropsPendingItemsInvalidatesTheWorkerAndRefusesItsFinish() async {
        let queue = ChangeQueue<String>()
        queue.append("a")
        let gate = Gate()
        var finished: Bool?
        var cancelledWhileWaiting = false
        queue.startIfIdle { generation in
            await gate.wait()
            cancelledWhileWaiting = Task.isCancelled
            finished = queue.finish(generation: generation)
        }
        let generation = queue.generation

        queue.cancel()

        #expect(queue.generation == generation + 1)
        #expect(queue.count == 0)
        #expect(!queue.isProcessing)
        #expect(!queue.isCurrent(generation))

        gate.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while finished == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(finished == false)
        #expect(cancelledWhileWaiting)

        // A new worker can start under the new generation.
        var newWorkerGeneration: Int?
        queue.startIfIdle { generation in
            newWorkerGeneration = generation
            _ = queue.finish(generation: generation)
        }
        while newWorkerGeneration == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(newWorkerGeneration == generation + 2)
    }

    @Test func finishingAStaleGenerationLeavesTheCurrentWorkerRunning() async {
        let queue = ChangeQueue<Int>()
        let gate = Gate()
        queue.startIfIdle { generation in
            await gate.wait()
            _ = queue.finish(generation: generation)
        }
        let current = queue.generation
        #expect(queue.finish(generation: current - 1) == false)
        #expect(queue.isProcessing)
        gate.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while queue.isProcessing, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!queue.isProcessing)
    }
}

/// Suspends a worker until the test opens it.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        isOpen = true
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
