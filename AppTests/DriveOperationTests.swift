/* Real app models with gated providers. MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

actor FixtureHardware: DriveHardwareServing {
    var drives: [DriveInfo]
    var heldDrive: UInt64?
    var statusByte: UInt8
    let sharedSerial: String?
    var failingEnumeration = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var inspections = 0
    private(set) var started = 0
    private(set) var logCalls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    init(drives: [DriveInfo] = [], heldDrive: UInt64? = nil, statusByte: UInt8 = 0, sharedSerial: String? = nil) {
        self.drives = drives; self.heldDrive = heldDrive; self.statusByte = statusByte
        self.sharedSerial = sharedSerial
    }
    func setEnumerationFailure() { failingEnumeration = true }
    func release() { held?.resume(); held = nil; heldDrive = nil }
    func enumerate() async throws -> [DriveInfo] {
        if failingEnumeration { throw HardwareWorkerError.remote("fixture discovery unavailable") }; return drives
    }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection {
        inspections += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if drive.id == heldDrive { await withCheckedContinuation { held = $0 } }
        else { try await Task.sleep(for: .milliseconds(15)) }
        let reading = DriveReading.ata(.init(capturedAt: Date(),
            identify: .init(model: drive.model, serialNumber: sharedSerial ?? drive.serialNumber ?? "", firmwareRevision: "F", rotationRate: 1),
            attributes: [], overallFailurePredicted: nil, selfTest: .init(rawByte: statusByte), driveFamily: nil, driveWarning: nil, selfTestSupported: true))
        return .init(reading: reading, skippedAsleep: false, volumes: [])
    }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { logCalls += 1; return [] }
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation {
        logCalls += 1
        let reading = ATASMARTReading(capturedAt: Date(), identify: .init(model: drive.model, serialNumber: sharedSerial ?? drive.serialNumber ?? "", firmwareRevision: "F", rotationRate: 1),
            attributes: [], overallFailurePredicted: nil, selfTest: .init(rawByte: statusByte), driveFamily: nil, driveWarning: nil, selfTestSupported: true)
        return .init(reading: reading, log: try .init(capturedAt: Date(), mostRecentSlot: 0, entries: []))
    }
    func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt {
        started += 1; return .init(runID: command.runID, acceptedAt: Date())
    }
}
private final class EngineCalls: @unchecked Sendable {
    private let lock = NSLock(); private var number = 0
    func increment() { lock.lock(); number += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return number }
}
private struct RejectingBenchmark: BenchmarkOperating {
    let calls: EngineCalls
    func run(volume: VolumeUsage, config: BenchmarkConfig, isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping DiskBenchmarkEngine.ProgressHandler) throws -> BenchmarkResult { calls.increment(); throw BenchmarkError.cancelled }
}
private struct RejectingCapacity: CapacityOperating {
    let calls: EngineCalls
    func run(volume: VolumeUsage, config: CapacityVerifyConfig, isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping CapacityVerifier.ProgressHandler) throws -> CapacityVerifyResult { calls.increment(); throw BenchmarkError.cancelled }
}
private actor NoEjectCommand: SystemCommandRunning {
    private(set) var count = 0
    func run(_ command: ProcessCommand) async throws -> CommandOutput { count += 1; throw HardwareWorkerError.protocolViolation }
}
private final class WriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var didEnter = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return didEnter }
    func wait() { condition.lock(); didEnter = true; while !released { condition.wait() }; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private struct HeldBenchmark: BenchmarkOperating {
    let gate: WriteGate
    func run(volume: VolumeUsage, config: BenchmarkConfig, isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping DiskBenchmarkEngine.ProgressHandler) throws -> BenchmarkResult { gate.wait(); throw BenchmarkError.cancelled }
}

final class DriveOperationTests: XCTestCase {
    @MainActor private var databases: [(DriveStore, URL)] = []
    override func tearDown() async throws {
        try await closeDatabases()
        try await super.tearDown()
    }
    @MainActor private func closeDatabases() async throws {
        for (store, url) in databases {
            store.beginShutdown()
            await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            try await store.history.shutdown()
            for suffix in ["", "-wal", "-shm"] {
                let path = url.path + suffix
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            }
        }
        databases.removeAll()
    }
    private func drive(_ id: UInt64) -> DriveInfo {
        .init(registryEntryID: id, bsdName: "disk\(id)", model: "Fixture", serialNumber: "fixture-\(id)",
              firmwareRevision: "F", sizeBytes: 1_000_000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
    }
    private var volume: VolumeUsage { .init(bsdName: "disk1s1", name: "Fixture", mountPoint: "/Volumes/Fixture", totalBytes: 1000, availableBytes: 900, sharedCapacityKey: "disk1s1") }
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("fixture condition did not arrive"); throw HardwareWorkerError.protocolViolation
    }
    @MainActor func testHeldProviderDoesNotHoldHealthyFleetPublicationAndWorkersAreBounded() async throws {
        let provider = FixtureHardware(drives: (1...9).map { drive(UInt64($0)) }, heldDrive: 1)
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: provider)
        let refresh = Task { await store.refresh() }
        try await waitUntil { store.snapshots.filter { $0.reading != nil }.count == 8 }
        XCTAssertTrue(store.isRefreshing); XCTAssertTrue(store.snapshots.first { $0.id == 1 }?.isProbing == true)
        XCTAssertTrue(store.snapshots.filter { $0.id != 1 }.allSatisfy { !$0.isProbing && $0.lastUpdated != nil })
        let maximum = await provider.maximumActive; XCTAssertEqual(maximum, 3)
        await provider.release(); await refresh.value
        XCTAssertFalse(store.isRefreshing); XCTAssertTrue(store.snapshots.allSatisfy { $0.reading != nil })
    }
    @MainActor func testEnumerationFailurePreservesFleetAndMarksReadingStale() async throws {
        let provider = FixtureHardware(drives: [drive(1)])
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: provider)
        await store.refresh(); let stamp = store.snapshots.first?.lastUpdated
        await provider.setEnumerationFailure(); await store.refresh()
        XCTAssertEqual(store.snapshots.count, 1); XCTAssertEqual(store.snapshots.first?.lastUpdated, stamp)
        XCTAssertTrue(store.snapshots.first?.isStale == true); XCTAssertNotNil(store.refreshError)
        XCTAssertNil(store.notificationTarget(for: try XCTUnwrap(store.snapshots.first?.identity.key)))
    }
    @MainActor func testNotificationRoutingWaitsForStreamingFleetCollisionResolution() async throws {
        let provider = FixtureHardware(drives: [drive(1), drive(2)], heldDrive: 2, sharedSerial: "SMART-SHARED")
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: provider)
        let refresh = Task { await store.refresh() }
        try await waitUntil { store.snapshots.first(where: { $0.id == 1 })?.reading != nil }
        let first = try XCTUnwrap(store.snapshots.first(where: { $0.id == 1 }))
        XCTAssertEqual(first.identity.source, .smartSerial)
        XCTAssertNil(store.notificationTarget(for: first.identity.key), "a later worker may reveal a duplicate serial")
        await provider.release(); await refresh.value
        XCTAssertEqual(store.snapshots.map { $0.identity.source }, [.ambiguous, .ambiguous])
        XCTAssertNil(store.notificationTarget(for: first.identity.key))
    }
    @MainActor func testEveryConflictingDrivePathUsesLeaseAndOtherDriveMayProbe() throws {
        let operations = DriveOperations()
        let probe = try operations.begin(driveID: 1, kind: .probe)
        for kind in [DriveOperationKind.probe, .selfTestLog, .selfTestStart, .eject, .benchmark, .capacity] {
            XCTAssertThrowsError(try operations.begin(driveID: 1, kind: kind))
        }
        let other = try operations.begin(driveID: 2, kind: .probe)
        operations.end(probe); operations.end(other)
        let log = try operations.begin(driveID: nil, kind: .kernelLog)
        XCTAssertThrowsError(try operations.begin(driveID: 1, kind: .benchmark), "measurement cannot race an existing log scan")
        operations.end(log)
        let measurement = try operations.begin(driveID: 1, kind: .capacity)
        for kind in [DriveOperationKind.probe, .selfTestLog, .selfTestStart, .eject, .discovery, .kernelLog, .trim] {
            XCTAssertThrowsError(try operations.begin(driveID: kind == .kernelLog ? nil : 2, kind: kind))
        }
        operations.end(measurement); XCTAssertTrue(operations.leases.isEmpty)
    }
    @MainActor func testStalledChildKeepsOwnershipUntilReaped() async throws {
        var command = ProcessCommand("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.08, scope: "model-pending-\(UUID())")
        command.terminateGrace = 0; command.killGrace = 0
        let pending: PendingChild
        do { _ = try await BoundedProcess.run(command); return XCTFail("must timeout") }
        catch let error as CommandError { pending = try XCTUnwrap(error.pendingChild) }
        let operations = DriveOperations(), lease = try operations.begin(driveID: 1, kind: .probe)
        operations.retainUntilExit(lease, pending: pending)
        XCTAssertTrue(operations.activity(for: 1)?.stalled == true)
        XCTAssertFalse(operations.canBegin(driveID: 1, kind: .eject))
        try await waitUntil { operations.activity(for: 1) == nil }
        XCTAssertTrue(pending.hasExited); XCTAssertTrue(operations.canBegin(driveID: 1, kind: .benchmark))
    }
    @MainActor func testMeasurementSuppressesServiceEntryPointsBeforeProviderOrCommands() async throws {
        let provider = FixtureHardware(drives: [drive(1)]), commands = NoEjectCommand()
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: provider)
        let lease = try store.operations.begin(driveID: 1, kind: .benchmark)
        await store.refresh()
        do { _ = try await store.readSelfTestLog(drive(1)); XCTFail("must reject") } catch {}
        do { try await store.startSelfTest(drive(1), extended: false); XCTFail("must reject") } catch {}
        guard case .failed = await store.eject(drive(1), volumes: [], force: true, runner: commands) else { return XCTFail("must reject before eject") }
        let inspections = await provider.inspections, logs = await provider.logCalls, starts = await provider.started, ejects = await commands.count
        XCTAssertEqual([inspections, logs, starts, ejects], [0, 0, 0, 0])
        store.operations.end(lease)
    }
    @MainActor func testRunnersRejectActiveProbeAndRunningFirmwareBeforeWriting() async throws {
        let provider = FixtureHardware(statusByte: 0xF5)
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: provider)
        let calls = EngineCalls(), runner = BenchmarkRunner(store: store, engine: RejectingBenchmark(calls: calls))
        let capacity = CapacityVerifyRunner(store: store, verifier: RejectingCapacity(calls: calls))
        let probe = try store.operations.begin(driveID: 1, kind: .probe)
        runner.start(snapshot: .init(drive: drive(1)), volume: volume, config: .init())
        XCTAssertFalse(runner.isRunning); XCTAssertEqual(calls.count, 0)
        store.operations.end(probe)
        runner.start(snapshot: .init(drive: drive(1)), volume: volume, config: .init())
        try await waitUntil { !runner.isRunning }
        guard case .failed = runner.state else { return XCTFail("fresh in-progress firmware must stop writing") }
        capacity.start(snapshot: .init(drive: drive(1)), volume: volume, config: .init())
        try await waitUntil { !capacity.isRunning }
        guard case .failed = capacity.state else { return XCTFail("capacity must perform the same preflight") }
        XCTAssertEqual(calls.count, 0); XCTAssertFalse(store.benchmarkInProgress)
    }
    @MainActor func testAcknowledgedSelfTestBlocksRestartAndMeasurementUntilFreshStatus() async throws {
        let provider = FixtureHardware(drives: [drive(1)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("self-test-owner-\(UUID()).db")
        let store = DriveStore(history: HistoryAccess(factory: { try HistoryStore(databaseURL: url) }), hardware: provider)
        databases.append((store, url))
        await store.refresh()
        try await store.startSelfTest(drive(1), extended: false)
        XCTAssertFalse(store.operations.canBegin(driveID: 1, kind: .benchmark))
        do { try await store.startSelfTest(drive(1), extended: true); XCTFail("repeat command must be rejected") } catch {}
        let starts = await provider.started; XCTAssertEqual(starts, 1)
        await store.refresh()
        XCTAssertFalse(store.operations.canBegin(driveID: 1, kind: .benchmark), "Terminal byte without a new log record cannot release run ownership")
    }
    @MainActor func testUnreturnedWriteCallMarksStalledAndKeepsBothLocksUntilThreadReturns() async throws {
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: FixtureHardware())
        let gate = WriteGate(), runner = BenchmarkRunner(store: store, engine: HeldBenchmark(gate: gate), stallTimeout: 0.05)
        defer { gate.release() }
        runner.start(snapshot: .init(drive: drive(1)), volume: volume, config: .init())
        try await waitUntil { gate.entered && runner.isStalled }
        XCTAssertTrue(runner.isRunning); XCTAssertTrue(store.benchmarkInProgress)
        XCTAssertTrue(store.operations.activity(for: 1)?.stalled == true)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 1), "OS lock must still exclude another process")
        do { try await store.startSelfTest(drive(1), extended: false); XCTFail("must keep ownership") } catch {}
        gate.release(); try await waitUntil { !runner.isRunning }
        XCTAssertFalse(runner.isStalled); XCTAssertFalse(store.benchmarkInProgress)
        let released = try DriveCommandLock.acquire(registryEntryID: 1); released.release()
    }
}
