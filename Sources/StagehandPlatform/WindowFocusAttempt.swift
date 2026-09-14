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
            // Some apps provide their focused window but no system-wide focused
            // application value. Require independent app and exact-window proof.
            return focusedApplicationStatus == AXError.noValue.rawValue &&
                frontmostPID == targetPID && directFocusedWindowStatus == AXError.success.rawValue &&
                directTargetWindowMatches
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
    func wait() async throws
}

@MainActor
enum WindowFocusAttempt {
    static func run(driver: some WindowFocusDriving, recordDiagnostics: Bool = true) async -> WindowFocusReport {
        let initialObservation = recordDiagnostics ? driver.observe() : nil
        let preparationOperations = driver.prepare()
        var operations = recordDiagnostics ? preparationOperations : []
        var observations: [WindowFocusReport.Observation] = []
        // Keep the original 180 ms retry budget, measured after preparation.
        let deadline = driver.elapsedMilliseconds + 180
        var attempt = 0
        var outcome = WindowFocusReport.Outcome.timedOut
        repeat {
            if Task.isCancelled {
                outcome = .cancelled
                break
            }
            let requestedOperations = driver.requestFocus(attempt: attempt)
            if recordDiagnostics { operations.append(contentsOf: requestedOperations) }
            let observation = driver.observe()
            if recordDiagnostics { observations.append(observation) }
            if observation.confirmsFocus(targetPID: driver.targetPID) {
                outcome = .focused
                break
            }
            attempt += 1
            do { try await driver.wait() } catch {
                outcome = .cancelled
                break
            }
        } while driver.elapsedMilliseconds < deadline
        // A slow AX read can consume the retry budget while activation completes.
        // Take one read-only snapshot at the deadline before reporting failure.
        if outcome == .timedOut {
            let observation = driver.observe()
            if recordDiagnostics { observations.append(observation) }
            if observation.confirmsFocus(targetPID: driver.targetPID) {
                outcome = .focused
            }
        }
        return WindowFocusReport(targetPID: driver.targetPID, outcome: outcome,
                                 elapsedMilliseconds: driver.elapsedMilliseconds,
                                 operations: operations, initialObservation: initialObservation,
                                 observations: observations)
    }
}
