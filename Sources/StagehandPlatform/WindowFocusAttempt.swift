import Foundation
import ApplicationServices

/// Contains only process IDs, timing, AX return codes, and focus identity checks.
/// No window titles, text-field contents, or keyboard events are collected.
public struct WindowFocusReport: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case focused, timedOut, cancelled, unavailable
    }

    public struct Operation: Codable, Equatable, Sendable {
        public let name: String
        public let accessibilityStatus: Int32?
        public let accepted: Bool?

        init(_ name: String, accessibilityStatus: Int32? = nil, accepted: Bool? = nil) {
            self.name = name
            self.accessibilityStatus = accessibilityStatus
            self.accepted = accepted
        }
    }

    public struct Observation: Codable, Equatable, Sendable {
        public let frontmostPID: Int32?
        public let focusedApplicationPID: Int32?
        public let focusedApplicationStatus: Int32
        public let focusedWindowStatus: Int32?
        public let directFocusedWindowStatus: Int32
        public let directTargetWindowMatches: Bool
        public let targetApplicationActive: Bool
        public let targetWindowMatches: Bool

        func confirmsFocus(targetPID: Int32) -> Bool {
            guard targetApplicationActive else { return false }
            if targetWindowMatches { return true }
            // The global AX focus can still point at Stagehand after its Start
            // menu closes. Trust the target app's exact window only when AppKit
            // also says that app is active and frontmost.
            let applicationUnavailable = Self.isUnavailable(focusedApplicationStatus)
            let focusedApplicationIsStagehand = focusedApplicationPID == ProcessInfo.processInfo.processIdentifier &&
                targetPID != ProcessInfo.processInfo.processIdentifier
            let windowUnavailable = focusedApplicationPID == targetPID &&
                focusedWindowStatus.map(Self.isUnavailable) == true
            return (applicationUnavailable || focusedApplicationIsStagehand || windowUnavailable) &&
                frontmostPID == targetPID &&
                directFocusedWindowStatus == AXError.success.rawValue && directTargetWindowMatches
        }

        static func isUnavailable(_ status: Int32) -> Bool {
            status == AXError.noValue.rawValue || status == AXError.cannotComplete.rawValue ||
                status == AXError.invalidUIElement.rawValue
        }
    }

    public struct NativeObservation: Codable, Equatable, Sendable {
        public let applicationActive: Bool
        public let windowKey: Bool
        public let frontmostPID: Int32?
    }

    public let targetPID: Int32?
    public let outcome: Outcome
    public let elapsedMilliseconds: Int
    public let operations: [Operation]
    public let initialObservation: Observation?
    public let observations: [Observation]
    public let nativeObservation: NativeObservation?

    init(targetPID: Int32?, outcome: Outcome, elapsedMilliseconds: Int, operations: [Operation],
         initialObservation: Observation?, observations: [Observation], nativeObservation: NativeObservation? = nil) {
        self.targetPID = targetPID
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
        self.operations = operations
        self.initialObservation = initialObservation
        self.observations = observations
        self.nativeObservation = nativeObservation
    }

    public var summary: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "Focus outcome: \(outcome.rawValue); elapsed: \(elapsedMilliseconds) ms"
        }
        return text
    }
}

/// The live driver performs AX calls; tests supply observed focus and a virtual clock.
@MainActor
protocol WindowFocusDriving {
    var targetPID: Int32 { get }
    var elapsedMilliseconds: Int { get }
    func prepare() -> [WindowFocusReport.Operation]
    func requestFocus(attempt: Int) -> [WindowFocusReport.Operation]
    func observe() -> WindowFocusReport.Observation
    func wait(milliseconds: Int) async throws
}

@MainActor
enum WindowFocusAttempt {
    static func run(driver: some WindowFocusDriving, recordDiagnostics: Bool = true) async -> WindowFocusReport {
        if Task.isCancelled {
            return WindowFocusReport(targetPID: driver.targetPID, outcome: .cancelled,
                                     elapsedMilliseconds: driver.elapsedMilliseconds,
                                     operations: [], initialObservation: nil, observations: [])
        }
        let initialObservation = recordDiagnostics ? driver.observe() : nil
        if Task.isCancelled {
            return WindowFocusReport(targetPID: driver.targetPID, outcome: .cancelled,
                                     elapsedMilliseconds: driver.elapsedMilliseconds,
                                     operations: [], initialObservation: initialObservation, observations: [])
        }
        let preparationOperations = driver.prepare()
        var operations = recordDiagnostics ? preparationOperations : []
        var observations: [WindowFocusReport.Observation] = []
        // Most switches finish in the first 180 ms. Allow slow activation some
        // time without repeatedly sending AX setters, then extend only while
        // the target is active or AX itself is temporarily unavailable.
        let fastDeadline = driver.elapsedMilliseconds + 180
        let activationDeadline = driver.elapsedMilliseconds + 600
        let recoveryDeadline = driver.elapsedMilliseconds + 1_500
        var attempt = 0
        var outcome = WindowFocusReport.Outcome.timedOut
        var targetBecameActive = false
        var accessibilityUnavailable = false
        var finalObservationDue = false
        var lastRequestAt: Int?
        while true {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            let elapsed = driver.elapsedMilliseconds
            let shouldRequest = lastRequestAt.map {
                (elapsed < fastDeadline && !targetBecameActive) || elapsed - $0 >= 120
            } ?? true
            if !finalObservationDue && shouldRequest {
                let requestedOperations = driver.requestFocus(attempt: attempt)
                if recordDiagnostics { operations.append(contentsOf: requestedOperations) }
                lastRequestAt = elapsed
                attempt += 1
            }
            let observation = driver.observe()
            if recordDiagnostics { observations.append(observation) }
            if observation.confirmsFocus(targetPID: driver.targetPID) {
                outcome = .focused
                break
            }
            if observation.targetApplicationActive, observation.frontmostPID == driver.targetPID {
                targetBecameActive = true
            }
            if WindowFocusReport.Observation.isUnavailable(observation.focusedApplicationStatus) ||
                observation.focusedWindowStatus.map(WindowFocusReport.Observation.isUnavailable) == true ||
                WindowFocusReport.Observation.isUnavailable(observation.directFocusedWindowStatus) {
                accessibilityUnavailable = true
            }
            let currentDeadline = targetBecameActive || accessibilityUnavailable
                ? recoveryDeadline : activationDeadline
            if driver.elapsedMilliseconds >= currentDeadline {
                if finalObservationDue { break }
                finalObservationDue = true
            } else {
                finalObservationDue = false
            }
            do { try await driver.wait(milliseconds: driver.elapsedMilliseconds < fastDeadline ? 8 : 40) } catch {
                outcome = .cancelled
                break
            }
        }
        return WindowFocusReport(targetPID: driver.targetPID, outcome: outcome,
                                 elapsedMilliseconds: driver.elapsedMilliseconds,
                                 operations: operations, initialObservation: initialObservation,
                                 observations: observations)
    }
}
