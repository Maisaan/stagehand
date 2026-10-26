import Darwin
import Testing
@testable import Stagehand

/// Rates cover the time since the previous sample; the first sample has only levels.
@Test func resourceSamplesReportLevelsAndRatesSinceThePreviousSample() {
    let first = ResourceSampler.Usage(footprintBytes: 20 * 1_048_576, cpuNanoseconds: 1_000_000_000,
                                      idleWakeups: 100, interruptWakeups: 50, threads: 9, uptime: 1_000)
    #expect(ResourceSampler.details(first, since: nil) == ["footprintMegabytes": "20.0", "threads": "9"])
    let second = ResourceSampler.Usage(footprintBytes: 21 * 1_048_576, cpuNanoseconds: 1_300_000_000,
                                       idleWakeups: 160, interruptWakeups: 50, threads: 9, uptime: 1_060)
    let details = ResourceSampler.details(second, since: first)
    #expect(details["periodSeconds"] == "60")
    #expect(details["cpuPercent"] == "0.50")
    #expect(details["idleWakeupsPerSecond"] == "1.0")
    #expect(details["interruptWakeupsPerSecond"] == "0.0")
}

@Test func resourceUsageAndThreadCPUCanBeRead() {
    let usage = ResourceSampler.currentUsage()
    #expect((usage?.footprintBytes ?? 0) > 0)
    #expect((usage?.threads ?? 0) > 0)
    let thread = mach_thread_self()
    let before = MainThreadWatchdog.cpuMicroseconds(thread)
    var x = 0.0
    for i in 0..<2_000_000 { x += sqrt(Double(i)) }
    #expect(x > 0)
    let after = MainThreadWatchdog.cpuMicroseconds(thread)
    #expect(before != nil && after != nil && after! > before!)
}
