import AppKit
import Testing
@testable import StagehandPlatform

@Test func processLookupByExecutablePathFindsTheRunningProcess() throws {
    // AppKit reports some apps, such as Xcode's Device Hub, with pid -1; their
    // pid is then recovered from the process table by executable path.
    let pid = getpid()
    let path = try #require(ProcessIdentifierResolver.executablePath(pid: pid))
    let started = ProcessLaunchDate.kernelStartDate(pid: pid)
    #expect(ProcessIdentifierResolver.findProcess(path: path, launchDate: started) == pid)
    #expect(ProcessIdentifierResolver.findProcess(path: path + ".missing", launchDate: nil) == nil)
}
