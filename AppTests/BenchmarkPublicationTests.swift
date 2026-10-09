/* Finished measurements and durable history have distinct publication times. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private final class BenchmarkOpenGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    func open(_ url: URL) throws -> HistoryStore {
        lock.lock(); didEnter = true; lock.unlock()
        guard signal.wait(timeout: .now() + 10) == .success else { throw HistoryError.unavailable }
        return try HistoryStore(databaseURL: url)
    }
    func release() { signal.signal() }
}
private struct PublicationBenchmark: BenchmarkOperating {
    func run(volume: VolumeUsage, config: BenchmarkConfig, isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping DiskBenchmarkEngine.ProgressHandler) throws -> BenchmarkResult {
        .init(capturedAt: Date(), volumeBSDName: volume.bsdName, volumeName: volume.name, mountPoint: volume.mountPoint,
            fileSizeBytes: config.fileSizeBytes, sequentialBlockBytes: config.sequentialBlockBytes, randomBlockBytes: config.randomBlockBytes,
            queueDepth: config.queueDepth, sequentialWriteBytesPerSec: 100, sequentialReadBytesPerSec: 200,
            randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
}

final class BenchmarkPublicationTests: XCTestCase {
    @MainActor private var fixtures: [(DriveStore, URL, BenchmarkOpenGate?)] = []
    override func tearDown() async throws {
        try await drain(); try await super.tearDown()
    }
    @MainActor private func drain() async throws {
        for (store, root, gate) in fixtures {
            gate?.release(); store.beginShutdown(); await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            try await store.history.shutdown(); try FileManager.default.removeItem(at: root)
        }
        fixtures.removeAll()
    }
    @MainActor private func setup(gated: Bool) throws -> (DriveStore, DriveSnapshot, BenchmarkOpenGate?) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("benchmark-publication-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let gate = gated ? BenchmarkOpenGate() : nil, database = root.appendingPathComponent("history.sqlite")
        let access = HistoryAccess(factory: {
            if let gate { return try gate.open(database) }
            throw HistoryError.unavailable
        })
        let store = DriveStore(history: access, hardware: FixtureHardware(drives: []),
                               measurementRecovery: SystemMeasurementRecovery(rootURL: root.appendingPathComponent("journal")))
        fixtures.append((store, root, gate))
        let drive = DriveInfo(registryEntryID: UInt64(ProcessInfo.processInfo.processIdentifier) << 32 | 827,
            bsdName: "disk999999", model: "Publication fixture", serialNumber: "PUBLICATION-ONLY", firmwareRevision: "F",
            sizeBytes: 1 << 30, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999999s1", name: "Private fixture", mountPoint: root.path,
                                totalBytes: 1 << 30, availableBytes: 1 << 30, sharedCapacityKey: "private")
        return (store, .init(drive: drive, volumes: [volume]), gate)
    }

    @MainActor func testFinishedResultIsAvailableBeforeCommitButHistoryPublicationWaits() async throws {
        let (store, snapshot, optionalGate) = try setup(gated: true), runner = BenchmarkRunner(store: store, engine: PublicationBenchmark())
        let gate = try XCTUnwrap(optionalGate); defer { gate.release() }
        let before = runner.historyRevision
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init())
        let deadline = ContinuousClock().now + .seconds(5)
        while !gate.entered && ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.entered)
        guard case .finished = runner.state else { return XCTFail("\(runner.state)") }
        XCTAssertTrue(runner.isSaving); XCTAssertEqual(runner.unsavedResults.count, 1)
        XCTAssertEqual(runner.historyRevision, before)
        gate.release(); await runner.waitForCompletion()
        XCTAssertNotEqual(runner.historyRevision, before)
        XCTAssertFalse(runner.isSaving); XCTAssertTrue(runner.unsavedResults.isEmpty)
        let rows = try await store.history.run("fixture.benchmark.query") { try await $0.benchmarks(driveKey: snapshot.identity.key, since: .distantPast) }
        XCTAssertEqual(rows.count, 1)
        let committed = runner.historyRevision
        await runner.retrySaving()
        XCTAssertEqual(runner.historyRevision, committed, "No pending write must not trigger another history reload")
    }

    @MainActor func testFailedWritePublishesStorageStateAndKeepsPendingResultAcrossRetry() async throws {
        let (store, snapshot, _) = try setup(gated: false), runner = BenchmarkRunner(store: store, engine: PublicationBenchmark())
        let before = runner.historyRevision
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init()); await runner.waitForCompletion()
        guard case .finished = runner.state else { return XCTFail("\(runner.state)") }
        XCTAssertNotEqual(runner.historyRevision, before)
        let id = try XCTUnwrap(runner.unsavedResults.first?.id)
        XCTAssertNotNil(runner.persistenceError); XCTAssertEqual(store.history.state, .unavailable)
        let failed = runner.historyRevision
        await runner.retrySaving(reconnect: true)
        XCTAssertNotEqual(runner.historyRevision, failed)
        XCTAssertEqual(runner.unsavedResults.map(\.id), [id]); XCTAssertNotNil(runner.persistenceError)
    }
}
