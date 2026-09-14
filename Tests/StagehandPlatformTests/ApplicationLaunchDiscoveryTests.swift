import Foundation
import Testing
@testable import StagehandPlatform

@Test @MainActor func launchDiscoveryIsBoundedAndCoalescesTheSameApp() async throws {
    let discovery = ApplicationLaunchDiscovery(delays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    var scans = 0
    discovery.schedule(pid: 123) { scans += 1; return true }
    discovery.schedule(pid: 123) { Issue.record("Duplicate launch scheduled"); return true }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while scans < 3 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(scans == 3)
}

@Test @MainActor func launchDiscoveryStopsWhenWindowIsFoundOrAppExits() async throws {
    let discovery = ApplicationLaunchDiscovery(delays: [.milliseconds(1), .milliseconds(1)])
    var scans = 0
    discovery.schedule(pid: 123) { scans += 1; return false }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while scans < 1 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(scans == 1)
}

@Test @MainActor func launchDiscoveryCancellationDoesNotRefreshOrCancelOtherApps() async throws {
    let discovery = ApplicationLaunchDiscovery(delays: [.milliseconds(1)])
    var scans = 0
    discovery.schedule(pid: 123) { Issue.record("Cancelled app refreshed"); return true }
    discovery.schedule(pid: 456) { scans += 1; return true }
    discovery.cancel(pid: 123)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while scans < 1 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(scans == 1)
    discovery.schedule(pid: 789) { Issue.record("Stopped discovery refreshed"); return true }
    discovery.cancelAll()
    try await Task.sleep(for: .milliseconds(10))
}
