import AppKit
import Testing
@testable import StagehandPlatform

@Test func kernelStartDateDescribesLiveProcesses() {
    let now = Date()
    let own = ProcessLaunchDate.kernelStartDate(pid: getpid())
    #expect(own != nil)
    #expect(own.map { $0 <= now && $0 > now.addingTimeInterval(-86_400) } == true)
    // launchd has no NSRunningApplication, so only the kernel can date it.
    #expect(NSRunningApplication(processIdentifier: 1) == nil)
    #expect(ProcessLaunchDate.launchDate(pid: 1) != nil)
    #expect(ProcessLaunchDate.kernelStartDate(pid: 0) == nil)
    #expect(ProcessLaunchDate.kernelStartDate(pid: -1) == nil)
}

@Test func launchDateAlwaysDatesTheCurrentProcess() throws {
    // The test host has no AppKit application connection, so go through the pid.
    let pid = getpid()
    let kernel = try #require(ProcessLaunchDate.kernelStartDate(pid: pid))
    let resolved = try #require(ProcessLaunchDate.launchDate(pid: pid))
    if let app = NSRunningApplication(processIdentifier: pid), let appKit = app.launchDate {
        // AppKit's date wins so journals written by earlier builds still match.
        #expect(resolved == appKit)
        #expect(abs(appKit.timeIntervalSince(kernel)) < 5)
        #expect(ProcessLaunchDate.launchDate(for: app) == appKit)
    } else {
        #expect(resolved == kernel)
    }
}

@Test func launchDateCoversAppsWithoutAppKitLaunchDate() throws {
    // Finder is the known case: AppKit reports no launch date for it.
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
          finder.launchDate == nil else { return }
    #expect(ProcessLaunchDate.launchDate(for: finder) != nil)
    #expect(ProcessLaunchDate.launchDate(pid: finder.processIdentifier) == ProcessLaunchDate.launchDate(for: finder))
}
