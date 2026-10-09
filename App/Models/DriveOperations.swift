/* Shared UI operation ownership. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import Observation
import MDriveHealthCore

enum DriveOperationKind: String, Sendable {
    case probe, selfTestLog, selfTestStart, eject, benchmark, capacity, discovery, kernelLog, trim, bridge, battery, sensors, memory, workspaceScan, workspaceCleanup
    var isMeasurement: Bool { self == .benchmark || self == .capacity }
    var conflictsWithSelfTest: Bool { isMeasurement || self == .eject || self == .selfTestStart || self == .workspaceCleanup }
    var isHardware: Bool { self != .kernelLog && self != .trim }
}
enum DriveOperationError: Error, LocalizedError {
    case busy, firmwareTest, cancelled, shuttingDown
    var errorDescription: String? {
        switch self {
        case .busy: return String(localized: "operation.busy", defaultValue: "Ổ hoặc tác vụ nền đang bận. Chờ thao tác hiện tại kết thúc rồi thử lại.")
        case .firmwareTest: return String(localized: "operation.firmwareTest", defaultValue: "Firmware self-test đang chạy hoặc chưa xác nhận trạng thái. Làm mới trước khi thao tác tiếp.")
        case .cancelled: return String(localized: "operation.cancelled", defaultValue: "Đã hủy trước khi bắt đầu ghi dữ liệu.")
        case .shuttingDown: return String(localized: "lifecycle.shuttingDown", defaultValue: "App đang dừng tác vụ và dọn file test.")
        }
    }
}

@MainActor @Observable final class DriveOperations {
    struct Lease: Sendable, Identifiable {
        let id = UUID()
        let driveID: UInt64?
        let kind: DriveOperationKind
        var stalled = false
    }
    private(set) var leases: [UUID: Lease] = [:]
    private(set) var firmwareTests: [UInt64: Date] = [:]
    private(set) var trackedSelfTests: Set<UInt64> = []
    private(set) var isResolvingFleet = false
    private(set) var isShuttingDown = false
    @ObservationIgnored private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var isMeasuring: Bool { leases.values.contains { $0.kind.isMeasurement } }
    func activity(for id: UInt64) -> Lease? { leases.values.first { $0.driveID == id } }
    func canBegin(driveID: UInt64?, kind: DriveOperationKind) -> Bool { rejection(driveID: driveID, kind: kind) == nil }
    private func rejection(driveID: UInt64?, kind: DriveOperationKind) -> DriveOperationError? {
        if isShuttingDown { return .shuttingDown }
        if isResolvingFleet && kind.conflictsWithSelfTest { return .busy }
        if isMeasuring || (kind.isMeasurement && !leases.isEmpty) { return .busy }
        if kind.isHardware && leases.values.filter({ $0.kind.isHardware }).count >= 3 { return .busy }
        if let driveID {
            if activity(for: driveID) != nil { return .busy }
            if kind.conflictsWithSelfTest && (firmwareTests[driveID] != nil || trackedSelfTests.contains(driveID)) { return .firmwareTest }
        } else if leases.values.contains(where: { $0.driveID == nil && $0.kind == kind }) { return .busy }
        return nil
    }
    func begin(driveID: UInt64?, kind: DriveOperationKind) throws -> Lease {
        if let error = rejection(driveID: driveID, kind: kind) { throw error }
        let lease = Lease(driveID: driveID, kind: kind); leases[lease.id] = lease; return lease
    }
    func beginRead(driveID: UInt64?, kind: DriveOperationKind) async throws -> Lease {
        let deadline = DispatchTime.now().uptimeNanoseconds + 12_000_000_000
        while true {
            try Task.checkCancellation()
            if isShuttingDown { throw DriveOperationError.shuttingDown }
            if isMeasuring { throw DriveOperationError.busy }
            if canBegin(driveID: driveID, kind: kind) { return try begin(driveID: driveID, kind: kind) }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw DriveOperationError.busy }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    func end(_ lease: Lease) {
        leases.removeValue(forKey: lease.id)
        if leases.isEmpty { let waiters = idleWaiters; idleWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
    }
    func beginShutdown() { isShuttingDown = true }
    func resumeAfterShutdown() { isShuttingDown = false }
    func waitForIdle() async {
        if !leases.isEmpty { await withCheckedContinuation { idleWaiters.append($0) } }
    }
    func markStalled(_ lease: Lease) { leases[lease.id]?.stalled = true }
    /// Keep ownership and any cross-process lock until OS exit confirmation.
    func retainUntilExit(_ lease: Lease, pending: PendingChild, diskLock: DriveCommandLock.Lease? = nil) {
        guard leases[lease.id] != nil else { diskLock?.release(); return }
        leases[lease.id]?.stalled = true
        Task {
            await pending.waitForExit()
            diskLock?.release(); end(lease)
        }
    }
    func fail(_ lease: Lease, error: Error) {
        if let pending = (error as? CommandError)?.pendingChild { retainUntilExit(lease, pending: pending) }
        else { end(lease) }
    }
    func confirmedSelfTestStart(driveID: UInt64) { firmwareTests[driveID] = Date() }
    func beginFleetResolution() { isResolvingFleet = true }
    func endFleetResolution() { isResolvingFleet = false }
    func trackSelfTest(driveID: UInt64, active: Bool) {
        if active { trackedSelfTests.insert(driveID) } else { trackedSelfTests.remove(driveID) }
    }
    func retainAttachedFirmwareTests(_ ids: Set<UInt64>) {
        firmwareTests = firmwareTests.filter { ids.contains($0.key) }
        trackedSelfTests.formIntersection(ids)
    }
    func observe(_ reading: DriveReading, driveID: UInt64) {
        guard let status = reading.ataSelfTest else { return }
        if status.inProgress { firmwareTests[driveID] = firmwareTests[driveID] ?? reading.capturedAt }
        else if let started = firmwareTests[driveID], reading.capturedAt >= started { firmwareTests.removeValue(forKey: driveID) }
    }
}

/// An unreturned filesystem call cannot be interrupted by Task cancellation.
/// Surface lack of progress, request cancellation and keep the write lease
/// until the dedicated thread returns and the engine has completed cleanup.
@MainActor final class WriteOperationWatchdog {
    private let timeout: TimeInterval
    private var lastProgress = DispatchTime.now().uptimeNanoseconds
    private var task: Task<Void, Never>?
    init(timeout: TimeInterval) { self.timeout = timeout.isFinite && timeout > 0 ? timeout : 30 }
    func ping() { lastProgress = DispatchTime.now().uptimeNanoseconds }
    func start(timeoutOverride: TimeInterval? = nil, onStall: @escaping @MainActor () -> Void) {
        stop(); ping()
        let interval = timeoutOverride ?? timeout
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(min(1, interval))) } catch { return }
                if Double(DispatchTime.now().uptimeNanoseconds - lastProgress) / 1e9 >= interval { onStall(); return }
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

protocol DriveHardwareServing: Sendable {
    func enumerate() async throws -> [DriveInfo]
    func bridge(_ drive: DriveInfo) async throws -> USBBridgeInfo?
    func battery() async throws -> BatteryInfo?
    func sensors() async throws -> [TemperatureSensor]
    func memory() async throws -> MemoryStats?
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection
    func measurementStatus(_ drive: DriveInfo, lease: DriveCommandLock.Lease) async throws -> HardwareInspection?
    func validate(_ drive: DriveInfo) async throws
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry]
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation
    func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan
    func cleanupWorkspace(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) async throws
}
extension DriveHardwareServing {
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan { throw HardwareWorkerError.protocolViolation }
    func cleanupWorkspace(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) async throws { throw HardwareWorkerError.protocolViolation }
    func measurementStatus(_ drive: DriveInfo, lease: DriveCommandLock.Lease) async throws -> HardwareInspection? {
        if drive.smartInterface == .ata { return try await inspect(drive, avoidWakingIdle: false) }
        try await validate(drive); return nil
    }
    func bridge(_ drive: DriveInfo) async throws -> USBBridgeInfo? { throw HardwareWorkerError.protocolViolation }
    func battery() async throws -> BatteryInfo? { throw HardwareWorkerError.protocolViolation }
    func sensors() async throws -> [TemperatureSensor] { throw HardwareWorkerError.protocolViolation }
    func memory() async throws -> MemoryStats? { throw HardwareWorkerError.protocolViolation }
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation { throw HardwareWorkerError.protocolViolation }
    func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt { throw SelfTestCommandError.notIssued("Unavailable hardware provider") }
}
struct SystemDriveHardware: DriveHardwareServing {
    let client: HardwareWorkerClient
    init() {
        let path = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MDriveHealthWorker").path ?? "/MDriveHealthWorker-unavailable"
        client = HardwareWorkerClient(executable: path)
    }
    func enumerate() async throws -> [DriveInfo] {
        guard case .drives(let drives) = try await client.perform(.enumerate) else { throw HardwareWorkerError.protocolViolation }; return drives
    }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection {
        guard case .inspection(let value) = try await client.perform(.inspect(drive, avoidWakingIdle: avoidWakingIdle)) else { throw HardwareWorkerError.protocolViolation }; return value
    }
    func validate(_ drive: DriveInfo) async throws { _ = try await client.perform(.validate(drive)) }
    func measurementStatus(_ drive: DriveInfo, lease: DriveCommandLock.Lease) async throws -> HardwareInspection? {
        switch try await client.measurementStatus(drive, lease: lease) {
        case .acknowledged: return nil
        case .inspection(let value): return value
        default: throw HardwareWorkerError.protocolViolation
        }
    }
    func bridge(_ drive: DriveInfo) async throws -> USBBridgeInfo? {
        guard case .bridge(let value) = try await client.perform(.bridge(drive)) else { throw HardwareWorkerError.protocolViolation }; return value
    }
    func battery() async throws -> BatteryInfo? {
        guard case .battery(let value) = try await client.perform(.battery) else { throw HardwareWorkerError.protocolViolation }; return value
    }
    func sensors() async throws -> [TemperatureSensor] {
        guard case .sensors(let value) = try await client.perform(.sensors) else { throw HardwareWorkerError.protocolViolation }; return value
    }
    func memory() async throws -> MemoryStats? {
        guard case .memory(let value) = try await client.perform(.memory) else { throw HardwareWorkerError.protocolViolation }; return value
    }
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] {
        guard case .selfTestLog(let value) = try await client.perform(.selfTestLog(drive)) else { throw HardwareWorkerError.protocolViolation }; return value
    }
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation {
        try await client.selfTestObservation(drive, lease: lease, avoidWakingIdle: avoidWakingIdle)
    }
    func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt {
        try await client.dispatchSelfTest(drive, command: command, lease: lease)
    }
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan {
        guard case .workspaces(let scan) = try await client.perform(.workspaces(drive, volume: volume)) else { throw HardwareWorkerError.protocolViolation }
        return scan
    }
    func cleanupWorkspace(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) async throws {
        try await client.cleanupWorkspace(drive, volume: volume, leftover: leftover, lease: lease)
    }
}
