/* Isolated IOKit worker protocol. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import Darwin

public enum HardwareOperation: Sendable, Codable {
    case enumerate, battery, sensors, memory
    case bridge(DriveInfo)
    case measurementStatus(DriveInfo, lockToken: UUID)
    case inspect(DriveInfo, avoidWakingIdle: Bool)
    case volumes(DriveInfo)
    case validate(DriveInfo)
    case selfTestLog(DriveInfo)
    case selfTestObservation(DriveInfo, lockToken: UUID, avoidWakingIdle: Bool)
    case dispatchSelfTest(DriveInfo, command: SelfTestCommand, lockToken: UUID)
    case workspaces(DriveInfo, volume: VolumeUsage)
    case cleanupWorkspace(DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lockToken: UUID)

    public var drive: DriveInfo? {
        switch self {
        case .enumerate, .battery, .sensors, .memory: return nil
        case .inspect(let d, _), .volumes(let d), .validate(let d), .selfTestLog(let d), .bridge(let d), .measurementStatus(let d, _), .selfTestObservation(let d, _, _), .dispatchSelfTest(let d, _, _), .workspaces(let d, _), .cleanupWorkspace(let d, _, _, _): return d
        }
    }
}
public struct HardwareInspection: Sendable, Codable {
    public let reading: DriveReading?
    public let skippedAsleep: Bool
    public let volumes: [VolumeUsage]
    public init(reading: DriveReading?, skippedAsleep: Bool, volumes: [VolumeUsage]) {
        self.reading = reading; self.skippedAsleep = skippedAsleep; self.volumes = volumes
    }
}
public enum HardwareValue: Sendable, Codable {
    case drives([DriveInfo]), inspection(HardwareInspection), volumes([VolumeUsage])
    case selfTestLog([ATASelfTestLogEntry]), acknowledged
    case selfTestObservation(SelfTestObservation), selfTestReceipt(SelfTestReceipt)
    case workspaces(DiskWorkspaceScan)
    case battery(BatteryInfo?), sensors([TemperatureSensor]), memory(MemoryStats?), bridge(USBBridgeInfo?)
}
public struct HardwareRequest: Sendable, Codable {
    public let version: Int
    public let id: UUID
    public let operation: HardwareOperation
    public init(operation: HardwareOperation) { version = 3; id = UUID(); self.operation = operation }
}
public struct HardwareReply: Sendable, Codable {
    public let version: Int
    public let id: UUID
    public let value: HardwareValue?
    public let failure: String?
    public let selfTestFailure: SelfTestFailureKind?
    public enum SelfTestFailureKind: String, Sendable, Codable { case notIssued, uncertain }
    public init(id: UUID, value: HardwareValue? = nil, failure: String? = nil, selfTestFailure: SelfTestFailureKind? = nil) {
        version = 3; self.id = id; self.value = value; self.failure = failure; self.selfTestFailure = selfTestFailure
    }
}
public enum HardwareWorkerError: Error, LocalizedError, Sendable {
    case protocolViolation, deviceChanged, selfTestRunning, selfTestUnavailable, deviceAsleep, remote(String)
    public var errorDescription: String? {
        switch self {
        case .protocolViolation: return "Invalid hardware worker reply"
        case .deviceChanged: return "Device attachment changed; refresh before retrying"
        case .selfTestRunning: return "The firmware self-test is already running"
        case .selfTestUnavailable: return "Current firmware self-test status is unavailable"
        case .deviceAsleep: return "Self-test log read skipped to preserve drive sleep"
        case .remote(let message): return message
        }
    }
}

public struct HardwareWorkerClient: Sendable {
    public let executable: String
    public var timeout: TimeInterval
    public var arguments: [String]
    public init(executable: String, arguments: [String] = [], timeout: TimeInterval = 12) { self.executable = executable; self.arguments = arguments; self.timeout = timeout }
    public func perform(_ operation: HardwareOperation) async throws -> HardwareValue {
        let request = HardwareRequest(operation: operation)
        return try decode(try await BoundedProcess.run(command(request)).requireSuccess(), for: request)
    }
    /// For CLI/dedicated threads only.
    public func performBlocking(_ operation: HardwareOperation) throws -> HardwareValue {
        let request = HardwareRequest(operation: operation)
        return try decode(try BoundedProcess.run(command(request)).requireSuccess(), for: request)
    }
    public func measurementStatus(_ drive: DriveInfo, lease: DriveCommandLock.Lease) async throws -> HardwareValue {
        defer { withExtendedLifetime(lease) {} }
        let request = HardwareRequest(operation: .measurementStatus(drive, lockToken: lease.token))
        var delegated = try command(request); delegated.inheritedFileDescriptors[3] = try lease.delegatedFD()
        return try decode(try await BoundedProcess.run(delegated).requireSuccess(), for: request)
    }
    public func measurementStatusBlocking(_ drive: DriveInfo, lease: DriveCommandLock.Lease) throws -> HardwareValue {
        defer { withExtendedLifetime(lease) {} }
        let request = HardwareRequest(operation: .measurementStatus(drive, lockToken: lease.token))
        var delegated = try command(request); delegated.inheritedFileDescriptors[3] = try lease.delegatedFD()
        return try decode(try BoundedProcess.run(delegated).requireSuccess(), for: request)
    }
    public func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool = false) async throws -> SelfTestObservation {
        let value = try await delegated(.selfTestObservation(drive, lockToken: lease.token, avoidWakingIdle: avoidWakingIdle), lease: lease)
        guard case .selfTestObservation(let observation) = value else { throw HardwareWorkerError.protocolViolation }
        return observation
    }
    public func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt {
        try command.validate()
        let value = try await delegated(.dispatchSelfTest(drive, command: command, lockToken: lease.token), lease: lease)
        guard case .selfTestReceipt(let receipt) = value else { throw HardwareWorkerError.protocolViolation }
        return receipt
    }
    public func cleanupWorkspace(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) async throws {
        guard case .acknowledged = try await delegated(.cleanupWorkspace(drive, volume: volume, leftover: leftover, lockToken: lease.token), lease: lease) else {
            throw HardwareWorkerError.protocolViolation
        }
    }
    public func cleanupWorkspaceBlocking(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) throws {
        defer { withExtendedLifetime(lease) {} }
        let request = HardwareRequest(operation: .cleanupWorkspace(drive, volume: volume, leftover: leftover, lockToken: lease.token))
        var delegated = try command(request); delegated.inheritedFileDescriptors[3] = try lease.delegatedFD()
        guard case .acknowledged = try decode(try BoundedProcess.run(delegated).requireSuccess(), for: request) else { throw HardwareWorkerError.protocolViolation }
    }
    private func delegated(_ operation: HardwareOperation, lease: DriveCommandLock.Lease) async throws -> HardwareValue {
        defer { withExtendedLifetime(lease) {} }
        let request = HardwareRequest(operation: operation)
        var delegated = try command(request); delegated.inheritedFileDescriptors[3] = try lease.delegatedFD()
        return try decode(try await BoundedProcess.run(delegated).requireSuccess(), for: request)
    }
    private func scope(for operation: HardwareOperation) -> String {
        if let drive = operation.drive { return "hardware:\(drive.id)" }
        switch operation {
        case .enumerate: return "hardware:enumeration"
        case .battery: return "hardware:battery"
        case .sensors: return "hardware:sensors"
        case .memory: return "hardware:memory"
        default: return "hardware:invalid"
        }
    }
    func command(_ request: HardwareRequest) throws -> ProcessCommand {
        var command = ProcessCommand(executable, arguments, timeout: timeout,
            scope: scope(for: request.operation))
        command.input = try JSONEncoder().encode(request)
        guard command.input.count <= DriveHardwareWorker.requestLimit else { throw HardwareWorkerError.protocolViolation }
        command.stdoutLimit = DriveHardwareWorker.replyLimit
        return command
    }
    func decode(_ bytes: Data, for request: HardwareRequest) throws -> HardwareValue {
        guard bytes.count <= DriveHardwareWorker.replyLimit,
              let reply = try? JSONDecoder().decode(HardwareReply.self, from: bytes),
              reply.version == 3, reply.id == request.id else { throw HardwareWorkerError.protocolViolation }
        if let failure = reply.failure {
            guard reply.value == nil, failure.utf8.count <= 4096 else { throw HardwareWorkerError.protocolViolation }
            if let kind = reply.selfTestFailure {
                guard case .dispatchSelfTest = request.operation else { throw HardwareWorkerError.protocolViolation }
                if kind == .notIssued { throw SelfTestCommandError.notIssued(failure) }
                throw SelfTestCommandError.uncertain(failure)
            }
            throw HardwareWorkerError.remote(failure)
        }
        guard reply.selfTestFailure == nil, let value = reply.value else { throw HardwareWorkerError.protocolViolation }
        switch (request.operation, value) {
        case (.enumerate, .drives(let drives)):
            guard drives.count <= 512, Set(drives.map(\.id)).count == drives.count,
                  drives.allSatisfy(DriveHardwareWorker.validDrive) else { throw HardwareWorkerError.protocolViolation }
        case (.inspect(let drive, _), .inspection(let inspection)):
            guard inspection.volumes.count <= 256,
                  !inspection.skippedAsleep || (inspection.reading == nil && inspection.volumes.isEmpty),
                  inspection.reading.map({ reading in
                      switch (drive.smartInterface, reading) { case (.nvme, .nvme), (.ata, .ata): return true; default: return false }
                  }) ?? true else { throw HardwareWorkerError.protocolViolation }
        case (.volumes, .volumes(let volumes)):
            guard volumes.count <= 256 else { throw HardwareWorkerError.protocolViolation }
        case (.workspaces(_, let volume), .workspaces(let scan)):
            guard volume.writeDirectoryIdentity?.isValid == true else { throw HardwareWorkerError.protocolViolation }
            try scan.validate(parentPath: DiskWorkspaceRecovery.writeDirectoryPath(for: volume), expectedParentIdentity: volume.writeDirectoryIdentity)
        case (.cleanupWorkspace, .acknowledged): break
        case (.selfTestLog, .selfTestLog(let entries)):
            guard entries.count <= 21 else { throw HardwareWorkerError.protocolViolation }
        case (.sensors, .sensors(let sensors)):
            guard sensors.count <= 1024, sensors.allSatisfy({ $0.celsius.isFinite && $0.name.utf8.count <= 1024 }) else { throw HardwareWorkerError.protocolViolation }
        case (.battery, .battery), (.memory, .memory), (.bridge, .bridge), (.validate, .acknowledged): break
        case (.selfTestObservation(let drive, _, _), .selfTestObservation(let observation)):
            guard drive.smartInterface == .ata else { throw HardwareWorkerError.protocolViolation }
            try observation.validate()
        case (.dispatchSelfTest(_, let command, _), .selfTestReceipt(let receipt)):
            try command.validate()
            guard receipt.runID == command.runID, receipt.acceptedAt.timeIntervalSince1970.isFinite,
                  receipt.acceptedAt >= command.baseline.capturedAt else { throw HardwareWorkerError.protocolViolation }
        case (.measurementStatus(let drive, _), .inspection(let inspection)):
            guard drive.smartInterface == .ata, case .ata? = inspection.reading, !inspection.skippedAsleep, inspection.volumes.isEmpty else { throw HardwareWorkerError.protocolViolation }
        case (.measurementStatus(let drive, _), .acknowledged):
            guard drive.smartInterface != .ata else { throw HardwareWorkerError.protocolViolation }
        default: throw HardwareWorkerError.protocolViolation
        }
        return value
    }
}

public enum DriveHardwareWorker {
    public static let requestLimit = 64 * 1024
    public static let replyLimit = 4 * 1_048_576
    static func validDrive(_ drive: DriveInfo) -> Bool {
        drive.id != 0 && drive.bsdName.range(of: "^disk[0-9]+$", options: .regularExpression) != nil
            && [drive.model, drive.serialNumber ?? "", drive.mediaUUID ?? "", drive.firmwareRevision ?? "", drive.interconnect, drive.location]
                .allSatisfy { $0.utf8.count <= 1024 && !$0.utf8.contains(0) }
    }
    public static func execute(_ operation: HardwareOperation) throws -> HardwareValue {
        switch operation {
        case .battery: return .battery(BatteryReader.read())
        case .sensors: return .sensors(SensorsReader.readTemperatures())
        case .memory: return .memory(MemoryReader.read())
        default: break
        }
        if case .enumerate = operation {
            // Validate the packaged resource before accepting a fleet. Missing
            // helper resources become worker failures, never silent fallbacks.
            _ = try DriveDB()
            let drives = try DriveEnumerator().enumerate()
            guard drives.count <= 512, drives.allSatisfy(validDrive) else { throw HardwareWorkerError.protocolViolation }
            return .drives(drives)
        }
        guard let expected = operation.drive, validDrive(expected),
              try DriveEnumerator().lookup(registryEntryID: expected.id) == expected else { throw HardwareWorkerError.deviceChanged }
        if case .validate = operation { return .acknowledged }
        if case .measurementStatus(_, let token) = operation {
            try DriveCommandLock.validateDelegation(registryEntryID: expected.id, token: token)
            if expected.smartInterface != .ata { return .acknowledged }
            return .inspection(.init(reading: .ata(try ATASMARTProvider(drive: expected).read()), skippedAsleep: false, volumes: []))
        }
        if case .selfTestObservation(_, let token, let avoidWakingIdle) = operation {
            try DriveCommandLock.validateDelegation(registryEntryID: expected.id, token: token)
            guard expected.smartInterface == .ata else { throw SMARTError.unsupportedTransport }
            return .selfTestObservation(try observeSelfTest(drive: expected, avoidWakingIdle: avoidWakingIdle,
                powerState: { DrivePower.isLikelyAsleep(registryEntryID: expected.id) }, read: { try observeSelfTest(expected) }))
        }
        if case .dispatchSelfTest(_, let command, let token) = operation {
            do { try DriveCommandLock.validateDelegation(registryEntryID: expected.id, token: token) }
            catch { throw SelfTestCommandError.notIssued(error.localizedDescription) }
            return .selfTestReceipt(try dispatchSelfTest(drive: expected, command: command,
                observe: { try observeSelfTest(expected) },
                dispatch: { try ATASMARTProvider(drive: expected).startSelfTest(extended: $0) }))
        }
        if case .cleanupWorkspace(_, let volume, let leftover, let token) = operation {
            try DriveCommandLock.validateDelegation(registryEntryID: expected.id, token: token)
            try validateWorkspaceVolume(volume, drive: expected)
            try DiskWorkspaceRecovery.cleanup(volume: volume, leftover: leftover)
            return .acknowledged
        }
        return try DriveCommandLock.withLock(registryEntryID: expected.id) {
            switch operation {
            case .enumerate, .battery, .sensors, .memory: throw HardwareWorkerError.protocolViolation
            case .bridge: return .bridge(USBBridgeReader.bridgeInfo(forDriveRegistryEntryID: expected.id))
            case .measurementStatus, .selfTestObservation, .dispatchSelfTest, .cleanupWorkspace: throw HardwareWorkerError.protocolViolation
            case .validate: return .acknowledged
            case .volumes:
                return .volumes(VolumeUsageReader.volumes(forDriveRegistryEntryID: expected.id))
            case .workspaces(_, let volume):
                try validateWorkspaceVolume(volume, drive: expected)
                return .workspaces(try DiskWorkspaceRecovery.scan(volume: volume))
            case .inspect(_, let avoidWakingIdle):
                return .inspection(try inspect(drive: expected, avoidWakingIdle: avoidWakingIdle,
                    powerState: { DrivePower.isLikelyAsleep(registryEntryID: expected.id) },
                    read: { try DriveProber.read(drive: expected) },
                    volumes: { VolumeUsageReader.volumes(forDriveRegistryEntryID: expected.id) }))
            case .selfTestLog:
                guard expected.smartInterface == .ata else { throw SMARTError.unsupportedTransport }
                return .selfTestLog(try ATASMARTProvider(drive: expected).readSelfTestLog())
            }
        }
    }
    static func validateWorkspaceVolume(_ volume: VolumeUsage, drive: DriveInfo) throws {
        let current = VolumeUsageReader.volumes(forDriveRegistryEntryID: drive.id).filter {
            $0.bsdName == volume.bsdName && $0.mountPoint == volume.mountPoint
                && $0.mountIdentity == volume.mountIdentity && $0.writeIdentity == volume.writeIdentity
                && $0.writeDirectoryIdentity == volume.writeDirectoryIdentity && volume.writeDirectoryIdentity?.isValid == true
                && $0.sharedCapacityKey == volume.sharedCapacityKey
        }
        guard current.count == 1 else { throw HardwareWorkerError.deviceChanged }
    }
    private static func observeSelfTest(_ drive: DriveInfo) throws -> SelfTestObservation {
        let provider = ATASMARTProvider(drive: drive)
        let reading = try provider.read()
        let observation = SelfTestObservation(reading: reading, log: try provider.readSelfTestLogSnapshot())
        try observation.validate(); return observation
    }
    static func observeSelfTest(drive: DriveInfo, avoidWakingIdle: Bool,
                                powerState: () -> Bool?, read: () throws -> SelfTestObservation) throws -> SelfTestObservation {
        guard drive.smartInterface == .ata else { throw SMARTError.unsupportedTransport }
        if avoidWakingIdle, !drive.isSolidState, powerState() == true { throw HardwareWorkerError.deviceAsleep }
        return try read()
    }
    /// The power check precedes both SMART and filesystem capacity reads. This
    /// also protects rotational USB devices without a supported SMART transport.
    static func inspect(drive: DriveInfo, avoidWakingIdle: Bool,
                        powerState: () -> Bool?, read: () throws -> DriveReading,
                        volumes: () -> [VolumeUsage]) throws -> HardwareInspection {
        if avoidWakingIdle, !drive.isVirtual, !drive.isSolidState, powerState() == true {
            return .init(reading: nil, skippedAsleep: true, volumes: [])
        }
        let reading = drive.smartInterface != .unsupported && !drive.isVirtual ? try read() : nil
        return .init(reading: reading, skippedAsleep: false, volumes: volumes())
    }
    /// Exactly one bounded request per child. No UI, persistent state or child spawning.
    public static func runStandardIO() -> Int32 {
        let parent = getppid(), expires = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        let guardian = Thread {
            while getppid() == parent && DispatchTime.now().uptimeNanoseconds < expires { Thread.sleep(forTimeInterval: 0.1) }
            Darwin.kill(getpid(), SIGKILL)
        }
        guardian.name = "MDriveHealth.worker-lifetime"; guardian.qualityOfService = .utility; guardian.start()
        do {
            var bytes = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                bytes.append(chunk)
                guard bytes.count <= requestLimit else { throw HardwareWorkerError.protocolViolation }
            }
            let request = try JSONDecoder().decode(HardwareRequest.self, from: bytes)
            guard request.version == 3 else { throw HardwareWorkerError.protocolViolation }
            let reply: HardwareReply
            do { reply = .init(id: request.id, value: try execute(request.operation)) }
            catch {
                var kind: HardwareReply.SelfTestFailureKind?
                if case .dispatchSelfTest = request.operation {
                    // All untyped failures here precede the command gate;
                    // the mutating boundary always throws a typed outcome.
                    if case SelfTestCommandError.uncertain = error { kind = .uncertain } else { kind = .notIssued }
                }
                reply = .init(id: request.id, failure: String(error.localizedDescription.prefix(1024)), selfTestFailure: kind)
            }
            let encoded = try JSONEncoder().encode(reply)
            guard encoded.count <= replyLimit else { throw HardwareWorkerError.protocolViolation }
            try FileHandle.standardOutput.write(contentsOf: encoded)
            return 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Hardware worker request failed\n".utf8))
            return 2
        }
    }
}
