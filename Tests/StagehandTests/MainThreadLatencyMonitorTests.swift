import Testing
@testable import Stagehand

@MainActor
@Test func latencyMonitorRestartedRightAfterStopKeepsOneSampler() async throws {
    let monitor = MainThreadLatencyMonitor()
    monitor.start()
    try await Task.sleep(for: .milliseconds(20))
    _ = monitor.stop()
    monitor.start()
    try await Task.sleep(for: .milliseconds(100))
    #expect(monitor.liveSamplers == 1)
    _ = monitor.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(monitor.liveSamplers == 0)
}
