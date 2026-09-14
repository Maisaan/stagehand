import ApplicationServices
import Testing
@testable import StagehandPlatform

@Test func launchingAppSubscriptionsRecoverAfterTransientFailure() {
    var observation = ApplicationObservation()
    var received: [String] = []
    #expect(observation.register { _ in .cannotComplete })
    #expect(!observation.register { name in
        received.append(name)
        return .success
    })
    #expect(received.contains(kAXWindowCreatedNotification))
    #expect(received.count == 4)
    #expect(observation.pending.isEmpty)
}

@Test func registrationRetriesOnlyTransientFailures() {
    var observation = ApplicationObservation()
    #expect(observation.register { name in
        switch name {
        case kAXWindowCreatedNotification: .cannotComplete
        case kAXFocusedWindowChangedNotification: .notificationAlreadyRegistered
        case kAXApplicationHiddenNotification: .notificationUnsupported
        default: .success
        }
    })
    var retried: [String] = []
    #expect(!observation.register { name in
        retried.append(name)
        return .success
    })
    #expect(retried == [kAXWindowCreatedNotification])
}

@Test func subscriptionRetriesAreBoundedAndCompletedSubscriptionsStayIdle() {
    var observation = ApplicationObservation()
    var calls = 0
    for _ in 0..<20 {
        _ = observation.register { _ in calls += 1; return .cannotComplete }
    }
    #expect(observation.attempts == 6)
    #expect(calls == 24)
    var complete = ApplicationObservation()
    _ = complete.register { _ in .success }
    #expect(!complete.register { _ in Issue.record("Completed subscriptions were retried"); return .success })
}
