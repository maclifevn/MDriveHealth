/* Actual runners with async worker boundary and owned child-exit fixture. GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

private actor RecordingMeasurements: MeasurementServing {
    enum Mode { case complete, hold, cleanupError, pendingExit, pendingCancellation }
    let mode: Mode
    private var released = false
    private(set) var benchmarkCalls = 0
    private(set) var capacityCalls = 0
    private(set) var id: UUID?
    private(set) var locked = false
    init(_ mode: Mode) { self.mode = mode }
    func release() { released = true }
    private func record(_ drive: DriveInfo, id: UUID) {
        self.id = id
        do { let other = try DriveCommandLock.acquire(registryEntryID: drive.id); other.release() }
        catch { if case DriveCommandLockError.busy = error { locked = true } }
    }
    private func finish(cancelled: @escaping @Sendable () -> Bool) async throws {
        if mode == .pendingExit || mode == .pendingCancellation {
            // This test, rather than Process/Foundation or another supervisor,
            // transfers sole waitpid ownership to PendingChild.
            let argv = [strdup("/bin/sleep"),strdup("0.4"),nil]; defer { for pointer in argv { free(pointer) } }
            var pid: pid_t = 0
            let status = argv.withUnsafeBufferPointer { posix_spawn(&pid, "/bin/sleep", nil, nil, $0.baseAddress, environ) }
            guard status == 0 else { throw CommandError(.launch(status)) }
            throw CommandError(mode == .pendingCancellation ? .cancelled : .idleTimedOut, processID: pid, pendingChild: PendingChild(processID: pid))
        }
        while mode != .complete && !released && !cancelled() { try await Task.sleep(for: .milliseconds(5)) }
        if cancelled() {
            if mode == .cleanupError { throw BenchmarkError.cleanupFailed(path: "/fixture/owned-test") }
            throw BenchmarkError.cancelled
        }
    }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        benchmarkCalls += 1; record(drive, id: id)
        progress(.init(phase: .sequentialWrite, fractionCompleted: 0, instantaneousBytesPerSecond: 0, averageBytesPerSecond: 0))
        cleaning(0); try await finish(cancelled: cancelled)
        return .init(capturedAt: Date(), volumeBSDName: volume.bsdName, volumeName: volume.name, mountPoint: volume.mountPoint,
                     fileSizeBytes: config.fileSizeBytes, sequentialBlockBytes: config.sequentialBlockBytes, randomBlockBytes: config.randomBlockBytes,
                     queueDepth: config.queueDepth, sequentialWriteBytesPerSec: 100, sequentialReadBytesPerSec: 200,
                     randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult {
        capacityCalls += 1; record(drive, id: id); cleaning(0); try await finish(cancelled: cancelled)
        return .init(capturedAt: Date(), volumeName: volume.name, mountPoint: volume.mountPoint, bytesRequested: 8192, bytesWritten: 8192,
                     bytesVerifiedOK: 8192, firstCorruptionOffset: nil, corruptedBlocks: 0, writeBytesPerSec: 100, readBytesPerSec: 200,
                     verdict: .passedTestedRange, interruption: nil)
    }
}
final class MeasurementModelTests: XCTestCase {
    private var drive: DriveInfo { .init(registryEntryID: UInt64(getpid()) << 32 | 121, bsdName: "disk999999", model: "Fixture", serialNumber: "fixture",
                                        firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .unsupported) }
    private var volume: VolumeUsage { .init(bsdName: "disk999999s1", name: "Fixture", mountPoint: "/fixture", totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "disk999999s1") }
    @MainActor private func store() -> DriveStore { .init(history: .init(factory: { throw HistoryError.unavailable }), hardware: FixtureHardware()) }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("model never reached expected state")
    }
    @MainActor func testProductionPathCallsAsyncWorkerUnderLeaseAndKeepsStableUnsavedJobID() async throws {
        let store = store(), backend = RecordingMeasurements(.complete), runner = BenchmarkRunner(store: store, worker: backend)
        runner.start(snapshot: .init(drive: drive), volume: volume, config: .init())
        let id = try XCTUnwrap(runner.measurementID)
        try await waitUntil { !runner.isRunning && !runner.isSaving && runner.persistenceError != nil }
        let calls = await backend.benchmarkCalls, locked = await backend.locked, receivedID = await backend.id
        XCTAssertEqual(calls, 1); XCTAssertTrue(locked); XCTAssertEqual(receivedID, id)
        XCTAssertEqual(runner.unsavedResults.first?.id, id); XCTAssertFalse(store.benchmarkInProgress)
        guard case .finished = runner.state else { return XCTFail("storage failure must preserve completed worker result") }
        let next = try DriveCommandLock.acquire(registryEntryID: drive.id); next.release()
    }
    @MainActor func testCancellationWaitsForWorkerAndPreservesOwnershipDuringCleanup() async throws {
        let store = store(), backend = RecordingMeasurements(.hold), runner = BenchmarkRunner(store: store, worker: backend)
        runner.start(snapshot: .init(drive: drive), volume: volume, config: .init())
        try await waitUntil { runner.isCleaning }
        XCTAssertTrue(runner.isRunning); XCTAssertTrue(store.benchmarkInProgress)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: drive.id))
        runner.cancel(); try await waitUntil { !runner.isRunning }
        guard case .idle = runner.state else { return XCTFail("confirmed cancellation should return to idle") }
        XCTAssertFalse(store.benchmarkInProgress); XCTAssertTrue(runner.unsavedResults.isEmpty)
    }
    @MainActor func testCapacityUsesSameWorkerLeaseAndCancellationBoundary() async throws {
        let store = store(), backend = RecordingMeasurements(.hold), runner = CapacityVerifyRunner(store: store, worker: backend)
        runner.start(snapshot: .init(drive: drive), volume: volume, config: .init(dataRiskAcknowledged: true))
        try await waitUntil { runner.isCleaning }
        let calls = await backend.capacityCalls, locked = await backend.locked
        XCTAssertEqual(calls, 1); XCTAssertTrue(locked); XCTAssertTrue(store.benchmarkInProgress)
        runner.cancel(); try await waitUntil { !runner.isRunning }
        guard case .idle = runner.state else { return XCTFail("confirmed capacity cancellation should return to idle") }
        XCTAssertFalse(store.benchmarkInProgress)
    }
    @MainActor func testCleanupErrorRemainsVisibleAfterUserCancels() async throws {
        let store = store(), backend = RecordingMeasurements(.cleanupError), runner = BenchmarkRunner(store: store, worker: backend)
        runner.start(snapshot: .init(drive: drive), volume: volume, config: .init())
        try await waitUntil { runner.isCleaning }; runner.cancel(); try await waitUntil { !runner.isRunning }
        guard case .failed(let message) = runner.state else { return XCTFail("cleanup error must not become an ordinary cancel") }
        XCTAssertTrue(message.contains("/fixture/owned-test")); XCTAssertFalse(store.benchmarkInProgress)
    }
    @MainActor func testUnconfirmedChildExitRetainsBothOwnershipLayersUntilReaped() async throws {
        let store = store(), backend = RecordingMeasurements(.pendingExit), runner = BenchmarkRunner(store: store, worker: backend)
        runner.start(snapshot: .init(drive: drive), volume: volume, config: .init())
        try await waitUntil { !runner.isRunning }
        XCTAssertTrue(store.benchmarkInProgress); XCTAssertTrue(store.operations.activity(for: drive.id)?.stalled == true)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: drive.id))
        try await waitUntil { !store.benchmarkInProgress }
        let next = try DriveCommandLock.acquire(registryEntryID: drive.id); next.release()
    }
    @MainActor func testStalePublicationCannotReenterFinishedRunAfterReset() async throws {
        let store = store(), backend = RecordingMeasurements(.hold), runner = BenchmarkRunner(store: store, worker: backend)
        runner.start(snapshot: .init(drive: drive), volume: volume, config: .init())
        try await waitUntil { runner.isCleaning }; await backend.release(); try await waitUntil { !runner.isRunning }
        runner.reset(); try await Task.sleep(for: .milliseconds(25))
        guard case .idle = runner.state else { return XCTFail("delayed progress must not restore a finished run") }
        XCTAssertFalse(runner.isCleaning); XCTAssertNil(runner.progress)
    }
    @MainActor func testUnreapedCancellationStaysVisibleInBothRunners() async throws {
        let store = store(), backend = RecordingMeasurements(.pendingCancellation), benchmark = BenchmarkRunner(store: store, worker: backend)
        benchmark.start(snapshot: .init(drive: drive), volume: volume, config: .init())
        try await waitUntil { !benchmark.isRunning }
        guard case .failed(let message) = benchmark.state else { return XCTFail("unreaped cancellation is not confirmed completion") }
        XCTAssertTrue(message.contains("Child exit is still pending")); XCTAssertTrue(store.benchmarkInProgress)
        try await waitUntil { !store.benchmarkInProgress }
        let capacity = CapacityVerifyRunner(store: store, worker: backend)
        capacity.start(snapshot: .init(drive: drive), volume: volume, config: .init(dataRiskAcknowledged: true))
        try await waitUntil { !capacity.isRunning }
        guard case .failed(let capacityMessage) = capacity.state else { return XCTFail("capacity must preserve pending exit diagnostic") }
        XCTAssertTrue(capacityMessage.contains("Child exit is still pending")); XCTAssertTrue(store.benchmarkInProgress)
        try await waitUntil { !store.benchmarkInProgress }
    }
    @MainActor func testProgressFloodKeepsOnlyLatestValueBeforeMainActorDelivery() async throws {
        var seen: [Int] = []
        let publication = LatestProgress<Int> { seen.append($0) }
        // MainActor does not yield during submit: no per-value delivery queue.
        for index in 0..<100_000 { publication.submit(index) }
        XCTAssertTrue(seen.isEmpty)
        try await waitUntil { !seen.isEmpty }
        XCTAssertEqual(seen, [99_999])
    }
}
