import Testing
@testable import StagehandPlatform

/// The inventory poll keeps its base cadence while windows keep changing and
/// backs off, up to the maximum, while nothing changes.
@Test func inventoryPollBacksOffWhileUnchanged() {
    let base = WindowTuning.applicationInventoryPollSeconds
    let maximum = WindowTuning.applicationInventoryMaxPollSeconds
    #expect(WindowSystem.inventoryPollSeconds(unchangedPolls: 0) == base)
    #expect(WindowSystem.inventoryPollSeconds(unchangedPolls: 1) == base * 2)
    #expect(WindowSystem.inventoryPollSeconds(unchangedPolls: 2) == min(base * 4, maximum))
    #expect(WindowSystem.inventoryPollSeconds(unchangedPolls: 20) == maximum)
    #expect(WindowSystem.inventoryPollSeconds(unchangedPolls: -1) == base)
}
