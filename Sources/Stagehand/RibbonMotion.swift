import AppKit

/// Short-lived position-only animation. No resize calls, snapshots or idle timer.
@MainActor
final class RibbonMotion {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private(set) var frames: [String: CGRect] = [:]
    var isRunning: Bool { task != nil }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    func animate(from: [String: CGRect], to: [String: CGRect], duration: Double = 0.2,
                 update: @escaping ([String: CGRect]) -> Void, completion: @escaping () -> Void) {
        cancel()
        let currentGeneration = generation
        frames = from
        guard duration > 0, from != to else {
            frames = to
            update(to)
            guard generation == currentGeneration else { return }
            completion()
            return
        }
        task = Task { [weak self] in
            let start = ContinuousClock.now
            while !Task.isCancelled {
                guard let self, self.generation == currentGeneration else { return }
                let elapsed = start.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let progress = min(1, seconds / duration)
                self.frames = Self.interpolate(from: from, to: to, progress: progress)
                update(self.frames)
                guard !Task.isCancelled, self.generation == currentGeneration else { return }
                if progress >= 1 {
                    self.task = nil
                    completion()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    static func interpolate(from: [String: CGRect], to: [String: CGRect], progress: Double) -> [String: CGRect] {
        let progress = min(1, max(0, progress))
        // Solve Emil's existing ease-out curve (0.23, 1, 0.32, 1).
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2
            let x = 3 * (1 - t) * (1 - t) * t * 0.23 + 3 * (1 - t) * t * t * 0.32 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) / 2
        let eased = progress == 0 ? 0 : progress == 1 ? 1 : 1 - pow(1 - t, 3)
        return to.reduce(into: [:]) { result, item in
            let start = from[item.key] ?? item.value
            result[item.key] = CGRect(x: start.minX + (item.value.minX - start.minX) * eased,
                                      y: start.minY + (item.value.minY - start.minY) * eased,
                                      width: item.value.width, height: item.value.height)
        }
    }
}
