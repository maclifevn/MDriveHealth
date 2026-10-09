/* Tests compile the actual app models without launching the hardware UI.
 * MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private struct CompletedEngine: BenchmarkOperating {
    let result: BenchmarkResult
    func run(volume: VolumeUsage, config: BenchmarkConfig, isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping DiskBenchmarkEngine.ProgressHandler) throws -> BenchmarkResult { result }
}
private final class StorageMode: @unchecked Sendable {
    private let lock = NSLock()
    private var writable = false
    func allowWrites() { lock.lock(); writable = true; lock.unlock() }
    func open(_ url: URL) throws -> HistoryStore {
        lock.lock(); let writable = writable; lock.unlock()
        return try HistoryStore(databaseURL: url, accessMode: writable ? .readWrite : .readOnly)
    }
}

final class HistoryStateTests: XCTestCase {
    @MainActor private var fixtures: [(URL, DriveStore, BenchmarkRunner)] = []
    override func tearDown() async throws {
        try await closeFixtures()
        try await super.tearDown()
    }
    @MainActor private func closeFixtures() async throws {
        for (directory, store, runner) in fixtures {
            store.beginShutdown(); runner.cancel(); await runner.waitForCompletion()
            await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            try await store.history.shutdown()
            try FileManager.default.removeItem(at: directory)
        }
        fixtures.removeAll()
    }
    private func drive(serial: String? = "SN-A", model: String = "Test") -> DriveInfo {
        .init(registryEntryID: 1, bsdName: "disk2", model: model, serialNumber: serial,
              firmwareRevision: "F", sizeBytes: 1_000_000, interconnect: "USB", location: "External",
              isSolidState: true, smartInterface: .ata)
    }
    private var reading: DriveReading {
        .ata(.init(capturedAt: Date(), identify: .init(model: "Test", serialNumber: "SN-A", firmwareRevision: "F", rotationRate: 1),
                   attributes: [], overallFailurePredicted: nil, selfTest: nil, driveFamily: nil, driveWarning: nil))
    }
    private func result(_ stamp: TimeInterval = 1_700_000_000) -> BenchmarkResult {
        .init(capturedAt: Date(timeIntervalSince1970: stamp), volumeBSDName: "disk2s1", volumeName: "Test",
              mountPoint: "/Volumes/Test", fileSizeBytes: 4096, sequentialBlockBytes: 4096, randomBlockBytes: 4096,
              sequentialWriteBytesPerSec: 100, sequentialReadBytesPerSec: 200, randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
    private var volume: VolumeUsage {
        .init(bsdName: "disk2s1", name: "Test", mountPoint: "/Volumes/Test",
              totalBytes: 1_000_000, availableBytes: 900_000, sharedCapacityKey: "disk2s1")
    }
    @MainActor private func waitForSaveAttempt(_ runner: BenchmarkRunner) async throws {
        for _ in 0..<1000 {
            if !runner.isRunning && !runner.isSaving && (runner.persistenceError != nil || runner.unsavedResults.isEmpty) { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("benchmark completion/save attempt timed out")
    }
    @MainActor func testCompletedBenchmarkSurvivesSaveFailureResetAndSuccessfulRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("history.db"), seed = try HistoryStore(databaseURL: url)
        try await seed.close()
        let mode = StorageMode(), access = HistoryAccess(factory: { try mode.open(url) })
        let store = DriveStore(history: access, hardware: FixtureHardware()), expected = result()
        let runner = BenchmarkRunner(store: store, engine: CompletedEngine(result: expected))
        fixtures.append((directory, store, runner))
        let snapshot = DriveSnapshot(drive: drive())
        runner.start(snapshot: snapshot, volume: volume, config: BenchmarkConfig())
        try await waitForSaveAttempt(runner)
        guard case .finished(let displayed) = runner.state else { return XCTFail("a save failure must not turn a completed measurement into a failed benchmark") }
        XCTAssertEqual(displayed, expected)
        XCTAssertFalse(store.benchmarkInProgress, "SQLite failure must not retain disk ownership")
        XCTAssertEqual(runner.unsavedResults.count, 1)
        XCTAssertEqual(runner.unsavedResults.first?.driveKey, snapshot.identity.key)
        XCTAssertNotNil(runner.persistenceError)
        XCTAssertTrue(access.isDegraded)
        runner.reset()
        XCTAssertEqual(runner.unsavedResults.count, 1, "Run again must preserve unsaved results")
        await runner.retrySaving()
        XCTAssertEqual(runner.unsavedResults.count, 1)
        mode.allowWrites()
        await runner.retrySaving(reconnect: true)
        XCTAssertTrue(runner.unsavedResults.isEmpty); XCTAssertNil(runner.persistenceError)
        XCTAssertFalse(access.isDegraded)
        let saved = try await access.run("query") { try await $0.benchmarks(driveKey: snapshot.identity.key, since: .distantPast) }
        XCTAssertEqual(saved, [expected])
        await runner.retrySaving()
        let again = try await access.run("query") { try await $0.benchmarks(driveKey: snapshot.identity.key, since: .distantPast) }
        XCTAssertEqual(again.count, 1, "retry after success must not create duplicates")
    }
    @MainActor func testMultipleFailedRunsKeepEveryPendingResultInOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("history.db"), seed = try HistoryStore(databaseURL: url); try await seed.close()
        let mode = StorageMode(), access = HistoryAccess(factory: { try mode.open(url) })
        let store = DriveStore(history: access, hardware: FixtureHardware()), expected = result()
        let runner = BenchmarkRunner(store: store, engine: CompletedEngine(result: expected)), snapshot = DriveSnapshot(drive: drive())
        fixtures.append((directory, store, runner))
        for _ in 0..<2 {
            runner.start(snapshot: snapshot, volume: volume, config: BenchmarkConfig())
            try await waitForSaveAttempt(runner); runner.reset()
        }
        XCTAssertEqual(runner.unsavedResults.count, 2)
        mode.allowWrites(); await runner.retrySaving(reconnect: true)
        let saved = try await access.run("query") { try await $0.benchmarks(driveKey: snapshot.identity.key, since: .distantPast) }
        XCTAssertEqual(saved, [expected, expected]); XCTAssertTrue(runner.unsavedResults.isEmpty)
    }
    @MainActor func testTransientFailureKeepsReadingAndItsSMARTIdentity() {
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }))
        let now = Date(), old = DriveSnapshot(drive: drive(serial: "unknown"), reading: reading, health: reading.evaluateHealth(), lastUpdated: now)
        let failed = DriveSnapshot(drive: old.drive, lastError: "unavailable")
        let merged = store.merged(fresh: [failed], previous: [old])[0]
        XCTAssertNotNil(merged.reading); XCTAssertTrue(merged.isStale)
        XCTAssertEqual(merged.identity.key, old.identity.key)
        XCTAssertEqual(merged.lastUpdated, now)
    }
    @MainActor func testRegistryIDReusedForDifferentDeviceDoesNotCarryOldReading() {
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }))
        let old = DriveSnapshot(drive: drive(), reading: reading, health: reading.evaluateHealth())
        for replacement in [drive(serial: "SN-B"), drive(model: "Other model")] {
            let failed = DriveSnapshot(drive: replacement, lastError: "unavailable")
            let merged = store.merged(fresh: [failed], previous: [old])[0]
            XCTAssertNil(merged.reading); XCTAssertFalse(merged.isStale)
            XCTAssertNotEqual(merged.identity.key, old.identity.key)
        }
    }
    @MainActor func testSleepingUnsupportedDriveKeepsCapacityCacheWithoutSMARTReading() {
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }))
        var old = DriveSnapshot(drive: drive()); old.volumes = [volume]
        let sleeping = DriveSnapshot(drive: old.drive, skippedWhileSleeping: true)
        let carried = store.merged(fresh: [sleeping], previous: [old])[0]
        XCTAssertNil(carried.reading); XCTAssertEqual(carried.volumes, [volume])
        XCTAssertTrue(carried.skippedWhileSleeping)
        let failed = DriveSnapshot(drive: old.drive, lastError: "fixture unavailable")
        XCTAssertTrue(store.merged(fresh: [failed], previous: [old])[0].isStale)
        let replacement = DriveSnapshot(drive: drive(serial: "S-B"), skippedWhileSleeping: true)
        XCTAssertTrue(store.merged(fresh: [replacement], previous: [old])[0].volumes.isEmpty)
    }
    @MainActor func testCachedReadingCannotConcealDuplicateSerialFromFleetIsolation() {
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }))
        let unknown = drive(serial: "unknown")
        let old = DriveSnapshot(drive: unknown, reading: reading, health: reading.evaluateHealth())
        let failed = DriveSnapshot(drive: unknown, lastError: "probe failed")
        let otherDrive = DriveInfo(registryEntryID: 2, bsdName: "disk3", model: unknown.model,
            serialNumber: "unknown", firmwareRevision: "F", sizeBytes: unknown.sizeBytes,
            interconnect: "USB", location: "External", isSolidState: true, smartInterface: .ata)
        let other = DriveSnapshot(drive: otherDrive, reading: reading, health: reading.evaluateHealth())
        let fleet = store.resolvedFleet(fresh: [failed, other], previous: [old])
        XCTAssertTrue(fleet[0].isStale)
        XCTAssertEqual(fleet.map { $0.identity.source }, [.ambiguous, .ambiguous])
        XCTAssertNotEqual(fleet[0].identity.key, fleet[1].identity.key)
        let remaining = store.resolvedFleet(fresh: [other], previous: fleet)
        XCTAssertEqual(remaining[0].identity, fleet[1].identity, "removing one duplicate must not promote the other to an unsafe persistent key")
    }
}
