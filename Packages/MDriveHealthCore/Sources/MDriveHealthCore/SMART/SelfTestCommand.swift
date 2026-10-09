/* Guarded, delegated firmware command boundary. GPL-3.0-or-later. */
import Foundation

public enum SelfTestCommandError: Error, LocalizedError, Sendable {
    case notIssued(String), uncertain(String)
    public var errorDescription: String? {
        switch self {
        case .notIssued(let reason): return "Self-test command was not issued: \(reason)"
        case .uncertain(let reason): return "Self-test command acknowledgement is uncertain: \(reason)"
        }
    }
}
public struct SelfTestObservation: Sendable, Codable, Hashable {
    public let reading: ATASMARTReading
    public let log: ATASelfTestLog
    public init(reading: ATASMARTReading, log: ATASelfTestLog) { self.reading = reading; self.log = log }
    public func validate() throws {
        try log.validate()
        guard reading.capturedAt.timeIntervalSince1970.isFinite, reading.capturedAt <= log.capturedAt else {
            throw HardwareWorkerError.protocolViolation
        }
        if let status = reading.selfTest {
            guard status.statusCode <= 8 || (status.inProgress && (status.percentRemaining ?? 100) <= 90) else {
                throw HardwareWorkerError.protocolViolation
            }
        }
    }
}
public struct SelfTestCommand: Sendable, Codable {
    public let runID: UUID
    public let driveKey: String
    public let kind: SelfTestRunKind
    public let baseline: ATASelfTestLog
    public init(runID: UUID, driveKey: String, kind: SelfTestRunKind, baseline: ATASelfTestLog) {
        self.runID = runID; self.driveKey = driveKey; self.kind = kind; self.baseline = baseline
    }
    public func validate() throws {
        try baseline.validate()
        guard kind != .observed, !driveKey.isEmpty, driveKey.utf8.count <= 512, !driveKey.utf8.contains(0),
              baseline.latest?.inProgress != true else { throw HardwareWorkerError.protocolViolation }
    }
}
public struct SelfTestReceipt: Sendable, Codable, Hashable {
    public let runID: UUID
    public let acceptedAt: Date
    public init(runID: UUID, acceptedAt: Date) { self.runID = runID; self.acceptedAt = acceptedAt }
}

extension DriveHardwareWorker {
    /// Pure command gate, also used by tests with a recording dispatcher.
    /// All identity/status/log preconditions execute before the only mutating
    /// call. Failure after that call is explicitly uncertain, never retried.
    static func dispatchSelfTest(drive: DriveInfo, command: SelfTestCommand,
                                 observe: () throws -> SelfTestObservation,
                                 dispatch: (Bool) throws -> Void, now: () -> Date = Date.init) throws -> SelfTestReceipt {
        do {
            try command.validate()
            guard drive.smartInterface == .ata else { throw SMARTError.unsupportedTransport }
            let observation = try observe(); try observation.validate()
            guard DriveIdentity.resolve(for: drive, reading: .ata(observation.reading)).key == command.driveKey else {
                throw HardwareWorkerError.deviceChanged
            }
            guard observation.reading.selfTestSupported == true,
                  let status = observation.reading.selfTest else { throw HardwareWorkerError.selfTestUnavailable }
            guard !status.inProgress else { throw HardwareWorkerError.selfTestRunning }
            guard observation.log.capturedAt >= command.baseline.capturedAt,
                  observation.log.sameContents(as: command.baseline) else {
                throw SMARTError.invalidPayload("Self-test log changed since preflight; refresh before starting")
            }
        } catch { throw SelfTestCommandError.notIssued(error.localizedDescription) }
        do { try dispatch(command.kind == .extended) }
        catch let error as SelfTestCommandError { throw error }
        catch { throw SelfTestCommandError.uncertain(error.localizedDescription) }
        return .init(runID: command.runID, acceptedAt: now())
    }
}
