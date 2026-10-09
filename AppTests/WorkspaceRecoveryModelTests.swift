/* Actual app recovery, private temp ownership/inodes and OS leases. GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

private actor RecoveryHardware: DriveHardwareServing {
    let root: URL
    var override: DiskWorkspaceScan?
    var holdNext = false
    var held: CheckedContinuation<DiskWorkspaceScan, Error>?
    var heldResult: DiskWorkspaceScan?
    var pendingCleanup = false
    private(set) var scans = 0, cleanups = 0
    init(root: URL) { self.root = root }
    func set(_ scan: DiskWorkspaceScan?) { override = scan }
    func hold() { holdNext = true }
    func release() { held?.resume(returning: heldResult!); held = nil; heldResult = nil }
    func usePendingCleanup() { pendingCleanup = true }
    func enumerate() async throws -> [DriveInfo] { [] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection { throw HardwareWorkerError.protocolViolation }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan {
        scans += 1
        let actual = try DiskWorkspaceRecovery.scanFixture(at: root)
        let result = override.map { DiskWorkspaceScan(leftovers: $0.leftovers, complete: $0.complete, diagnostic: $0.diagnostic, parentIdentity: $0.parentIdentity ?? actual.parentIdentity) } ?? actual
        if holdNext {
            holdNext = false; heldResult = result
            return try await withCheckedThrowingContinuation { held = $0 }
        }
        return result
    }
    func cleanupWorkspace(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) async throws {
        cleanups += 1
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: drive.id), "parent's actual device lease excludes another owner")
        if pendingCleanup {
            let argv = [strdup("/bin/sleep"), strdup("0.3"), nil]; defer { for pointer in argv { free(pointer) } }
            var pid: pid_t = 0
            let status = argv.withUnsafeBufferPointer { posix_spawn(&pid, "/bin/sleep", nil, nil, $0.baseAddress, environ) }
            guard status == 0 else { throw CommandError(.launch(status)) }
            throw CommandError(.cancelled, processID: pid, pendingChild: PendingChild(processID: pid))
        }
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: leftover)
    }
}
private struct RecoveryFailedMeasurement: MeasurementServing {
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult { throw BenchmarkError.cleanupFailed(path: volume.mountPoint) }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult { throw BenchmarkError.cleanupFailed(path: volume.mountPoint) }
}
@MainActor private final class RecoverySilentDelivery: NotificationDelivering {
    var calls = 0
    func access() async -> NotificationAccess { calls += 1; return .denied }
    func requestPermission() async throws -> Bool { calls += 1; return false }
    func send(_ alert: DriveAlert) async throws { calls += 1 }
    func registeredRequestIDs() async -> Set<String> { calls += 1; return [] }
}
final class WorkspaceRecoveryModelTests: XCTestCase {
    private var root: URL!
    private var archivedRoots: [URL] = []
    @MainActor private var stores: [DriveStore] = []
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-workspaces-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDown() async throws {
        try await drain()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("outside".utf8))
        try FileManager.default.removeItem(at: root)
        for archived in archivedRoots { try FileManager.default.removeItem(at: archived) }
        archivedRoots.removeAll(); try await super.tearDown()
    }
    @MainActor private func drain() async throws {
        for store in stores {
            store.beginShutdown(); await store.operations.waitForIdle(); await store.waitForBackgroundWork(); try await store.history.shutdown()
        }
        stores.removeAll()
    }
    @MainActor private func make(history: HistoryAccess? = nil) -> (DriveStore, RecoveryHardware, DriveSnapshot) {
        let provider = RecoveryHardware(root: root), store = DriveStore(history: history ?? HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: provider)
        stores.append(store)
        let drive = DriveInfo(registryEntryID: UInt64(getpid()) << 32 | 912, bsdName: "disk999999", model: "Recovery fixture", serialNumber: "fixture", firmwareRevision: "F",
            sizeBytes: 1 << 40, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999999s1", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
            sharedCapacityKey: "fixture", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        return (store, provider, .init(drive: drive, volumes: [volume]))
    }
    @MainActor private func settle(_ store: DriveStore) async { await store.workspaces.waitForCompletion() }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("recovery fixture handshake timed out"); throw HistoryError.unavailable
    }
    private func owned(id: UUID = UUID()) throws -> String {
        var workspace: DiskTestWorkspace? = try DiskTestWorkspace.fixture(at: root, sessionID: id)
        let path = workspace!.directoryURL, name = path.lastPathComponent
        let fd = try workspace!.createFile("data.bin")
        let bytes = [UInt8](repeating: 0x71, count: 8192)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }, 8192); close(fd)
        // A temporary fixture link prevents destructor unlink. Remove it only
        // after writer FDs/volume lease close; the original then has one link
        // and its real journal/inode, with all 8 KiB still available to recover.
        let alias = root.appendingPathComponent("fixture-held-link")
        XCTAssertEqual(link(path.appendingPathComponent("data.bin").path, alias.path), 0)
        workspace = nil; XCTAssertEqual(unlink(alias.path), 0)
        return name
    }
    @MainActor func testStartupScansWithoutDeletingAndExplicitCleanupRechecksRealOwnership() async throws {
        let name = try owned(), (store, provider, snapshot) = make()
        store.workspaces.updateFleet([snapshot]); await settle(store)
        let record = try XCTUnwrap(store.workspaces.records.first), entry = try XCTUnwrap(record.scan?.leftovers.first)
        XCTAssertEqual(entry.bytes, 8192); XCTAssertEqual(entry.status, .recoverable)
        XCTAssertTrue(store.workspaces.hasFilesToReview)
        let before = await provider.cleanups; XCTAssertEqual(before, 0)
        let selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        await store.workspaces.cleanup(selection)
        XCTAssertTrue(store.workspaces.records.first?.scan?.leftovers.isEmpty == true)
        XCTAssertFalse(store.workspaces.hasFilesToReview)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entry.path))
        let after = await provider.cleanups; XCTAssertEqual(after, 1)
    }
    @MainActor func testStaleConfirmationAfterRescanCannotDelete() async throws {
        let name = try owned(), (store, provider, snapshot) = make()
        store.workspaces.updateFleet([snapshot]); await settle(store)
        let record = try XCTUnwrap(store.workspaces.records.first)
        let selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        store.workspaces.requestScan(record.id); await settle(store)
        XCTAssertFalse(store.workspaces.isCurrent(selection)); await store.workspaces.cleanup(selection)
        let count = await provider.cleanups; XCTAssertEqual(count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selection.leftover.path))
    }
    @MainActor func testUnknownFileInsertedAfterReviewIsPreservedAndRequiresFreshScan() async throws {
        let name = try owned(), (store, _, snapshot) = make()
        store.workspaces.updateFleet([snapshot]); await settle(store)
        let record = try XCTUnwrap(store.workspaces.records.first), selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        let unknown = URL(fileURLWithPath: selection.leftover.path).appendingPathComponent("new-user-file")
        try Data("keep".utf8).write(to: unknown); await store.workspaces.cleanup(selection)
        XCTAssertNotNil(store.workspaces.records.first?.error); XCTAssertFalse(store.workspaces.records.first?.isCurrent ?? true)
        XCTAssertEqual(try Data(contentsOf: unknown), Data("keep".utf8))
        store.workspaces.requestScan(record.id); await settle(store)
        XCTAssertEqual(store.workspaces.records.first?.scan?.leftovers.first?.status, .unverified)
        XCTAssertNil(store.workspaces.selection(recordID: record.id, name: name))
    }
    @MainActor func testPartialScanAndUnverifiedCandidatesNeverClearReviews() async throws {
        let (store, provider, snapshot) = make(), runner = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await runner.waitForCompletion()
        XCTAssertEqual(runner.workspaceReviews.count, 1)
        store.workspaces.onCompleteScan = { runner.reconcileWorkspaceReviews($0) }
        await provider.set(.init(leftovers: [], complete: false, diagnostic: "scan budget"))
        store.workspaces.updateFleet([snapshot]); await settle(store); XCTAssertEqual(runner.workspaceReviews.count, 1)
        XCTAssertTrue(store.workspaces.hasAttention)
        XCTAssertFalse(store.workspaces.hasFilesToReview)
        let legacy = DiskWorkspaceLeftover(name: BenchmarkLocation.testFileName, path: root.appendingPathComponent(BenchmarkLocation.testFileName).path,
            status: .unverified, bytes: nil, fileCount: nil, diagnostic: "missing manifest", proof: nil)
        await provider.set(.init(leftovers: [legacy], complete: true, diagnostic: nil))
        store.workspaces.requestScanAll(); await settle(store); XCTAssertEqual(runner.workspaceReviews.count, 1)
        XCTAssertTrue(store.workspaces.hasFilesToReview)
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil))
        store.workspaces.requestScanAll(); await settle(store); XCTAssertTrue(runner.workspaceReviews.isEmpty)
    }
    @MainActor func testFreshAbsenceClearsBothRunnersAndAllowsQuitGateToRecover() async throws {
        let database = root.appendingPathComponent("history.db")
        let history = HistoryAccess(factory: { try HistoryStore(databaseURL: database) })
        let (store, _, snapshot) = make(history: history), benchmark = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement()), capacity = CapacityVerifyRunner(store: store, worker: RecoveryFailedMeasurement())
        let suite = "workspace-quit-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite)), delivery = RecoverySilentDelivery()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKeys.monitoringEnabled)
        let monitor = MonitoringController(store: store, defaults: defaults, delivery: delivery, observePreferences: false)
        let lifecycle = ApplicationLifecycle(store: store, monitor: monitor, benchmark: benchmark, capacity: capacity, launch: { XCTFail("quit does not launch a second instance") })
        benchmark.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await benchmark.waitForCompletion()
        capacity.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(maxBytes: 16384)); await capacity.waitForCompletion()
        XCTAssertTrue(benchmark.requiresWorkspaceReview); XCTAssertTrue(capacity.requiresWorkspaceReview)
        let first = await lifecycle.prepare(.quit); XCTAssertFalse(first); XCTAssertNotNil(lifecycle.failure)
        await lifecycle.resume(); XCTAssertFalse(store.operations.isShuttingDown)
        store.workspaces.onCompleteScan = { benchmark.reconcileWorkspaceReviews($0); capacity.reconcileWorkspaceReviews($0) }
        store.workspaces.updateFleet([snapshot]); await settle(store)
        XCTAssertFalse(benchmark.requiresWorkspaceReview); XCTAssertFalse(capacity.requiresWorkspaceReview)
        let retry = await lifecycle.prepare(.quit); XCTAssertTrue(retry); XCTAssertTrue(lifecycle.isReady)
        XCTAssertEqual(delivery.calls, 0)
        XCTAssertEqual(history.state, .closed)
        do { _ = try await history.run("closed recovery") { _ in XCTFail("closed store must reject work before calling its body"); return 0 }; XCTFail("history admission must be closed after successful quit") }
        catch { guard case HistoryError.unavailable = error else { return XCTFail("unexpected error: \(error)") } }
    }
    @MainActor func testForeignScanPathIsUnavailableAndCannotPublishAbsenceEvidence() async throws {
        let (store, provider, snapshot) = make(); var evidence = 0
        let id = UUID(), name = DiskWorkspaceRecovery.workspaceName(for: id)
        await provider.set(.init(leftovers: [.init(name: name, path: "/foreign/" + name, status: .recoverable, bytes: 0, fileCount: 0, diagnostic: nil, proof: String(repeating: "a", count: 64))], complete: true, diagnostic: nil))
        store.workspaces.onCompleteScan = { _ in evidence += 1 }
        store.workspaces.updateFleet([snapshot]); await settle(store)
        XCTAssertEqual(evidence, 0); XCTAssertNotNil(store.workspaces.records.first?.error); XCTAssertFalse(store.workspaces.records.first?.isCurrent ?? true)
    }
    @MainActor func testDisconnectedCatalogRetainsKnownFilesAndInvalidatesConfirmation() async throws {
        let name = try owned(), (store, provider, snapshot) = make()
        store.workspaces.updateFleet([snapshot]); await settle(store)
        let record = try XCTUnwrap(store.workspaces.records.first), selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        store.workspaces.updateFleet([])
        XCTAssertFalse(store.workspaces.records.first?.attached ?? true); XCTAssertEqual(store.workspaces.records.first?.scan?.leftovers.count, 1)
        XCTAssertTrue(store.workspaces.hasFilesToReview)
        XCTAssertFalse(store.workspaces.isCurrent(selection)); await store.workspaces.cleanup(selection)
        let cleanups = await provider.cleanups; XCTAssertEqual(cleanups, 0)
    }
    @MainActor func testDuplicateVolumeIdentityAndSleepingDriveDoNotAutoScan() async throws {
        let (store, provider, snapshot) = make()
        store.workspaces.updateFleet([snapshot, snapshot]); await settle(store)
        XCTAssertTrue(store.workspaces.records.first?.ambiguous == true)
        var sleeping = snapshot; sleeping.skippedWhileSleeping = true
        store.workspaces.updateFleet([sleeping]); await settle(store)
        let before = await provider.scans; XCTAssertEqual(before, 0)
        XCTAssertNotNil(store.workspaces.records.first?.error)
        store.workspaces.requestScanAll(); await settle(store)
        let after = await provider.scans; XCTAssertEqual(after, 1)
    }
    @MainActor func testShutdownWaitsForHeldScanAndNoNewScanStarts() async throws {
        let (store, provider, snapshot) = make(); await provider.hold()
        store.workspaces.updateFleet([snapshot]); try await wait { store.operations.activity(for: snapshot.id)?.kind == .workspaceScan }
        var stopped = false
        store.beginShutdown(); let stop = Task { await store.waitForBackgroundWork(); stopped = true }
        store.workspaces.requestScanAll(); try await Task.sleep(for: .milliseconds(30)); XCTAssertFalse(stopped)
        await provider.release(); await stop.value
        XCTAssertTrue(stopped); XCTAssertFalse(store.workspaces.isBusy); XCTAssertTrue(store.operations.leases.isEmpty)
        let scans = await provider.scans; XCTAssertEqual(scans, 1)
    }
    @MainActor func testPendingCleanupChildRetainsActualDeviceLeaseUntilExit() async throws {
        let name = try owned(), (store, provider, snapshot) = make()
        store.workspaces.updateFleet([snapshot]); await settle(store); await provider.usePendingCleanup()
        let record = try XCTUnwrap(store.workspaces.records.first), selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        await store.workspaces.cleanup(selection)
        XCTAssertTrue(store.operations.activity(for: snapshot.id)?.stalled == true)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: snapshot.id))
        XCTAssertNil(store.workspaces.selection(recordID: record.id, name: name))
        await store.operations.waitForIdle()
        let lock = try DriveCommandLock.acquire(registryEntryID: snapshot.id); lock.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: selection.leftover.path))
    }
    @MainActor func testOldScanCannotOverwriteARepluggedAttachment() async throws {
        _ = try owned()
        let (store, provider, snapshot) = make(); await provider.hold()
        store.workspaces.updateFleet([snapshot]); try await wait { store.operations.activity(for: snapshot.id)?.kind == .workspaceScan }
        try await Task.sleep(for: .milliseconds(20))
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil))
        let drive = DriveInfo(registryEntryID: snapshot.id + 1, bsdName: "disk999998", model: snapshot.drive.model,
            serialNumber: snapshot.drive.serialNumber, firmwareRevision: "F", sizeBytes: snapshot.drive.sizeBytes,
            interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let replacement = DriveSnapshot(drive: drive, volumes: snapshot.volumes)
        store.workspaces.updateFleet([replacement])
        try await wait { store.workspaces.records.first?.isCurrent == true }
        await provider.release(); await settle(store)
        XCTAssertEqual(store.workspaces.records.first?.target.drive.id, drive.id)
        XCTAssertTrue(store.workspaces.records.first?.scan?.leftovers.isEmpty == true)
    }
    @MainActor func testDifferentVolumeUUIDCannotClearTheOriginalReview() async throws {
        let (store, provider, snapshot) = make(), runner = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await runner.waitForCompletion()
        store.workspaces.onCompleteScan = { runner.reconcileWorkspaceReviews($0) }
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil))
        let old = snapshot.volumes[0], original = try XCTUnwrap(old.mountIdentity)
        let other = MountedFilesystemIdentity(filesystemID: original.filesystemID, mountedFrom: original.mountedFrom, mountedAt: original.mountedAt, volumeUUID: UUID().uuidString)
        let volume = VolumeUsage(bsdName: old.bsdName, name: old.name, mountPoint: old.mountPoint, totalBytes: old.totalBytes, availableBytes: old.availableBytes,
            sharedCapacityKey: old.sharedCapacityKey, mountIdentity: other, writeIdentity: other, writeDirectoryIdentity: old.writeDirectoryIdentity)
        store.workspaces.updateFleet([.init(drive: snapshot.drive, volumes: [volume])]); await settle(store)
        XCTAssertTrue(runner.requiresWorkspaceReview)
        store.workspaces.updateFleet([snapshot]); await settle(store); XCTAssertFalse(runner.requiresWorkspaceReview)
    }
    @MainActor func testClonedFilesystemOnAnotherPhysicalDriveCannotClearOriginalReview() async throws {
        let (store, provider, snapshot) = make(), runner = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await runner.waitForCompletion()
        store.workspaces.onCompleteScan = { runner.reconcileWorkspaceReviews($0) }
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil))
        let other = DriveInfo(registryEntryID: snapshot.id + 1, bsdName: "disk999998", model: snapshot.drive.model,
            serialNumber: "different-physical-drive", firmwareRevision: "F", sizeBytes: snapshot.drive.sizeBytes,
            interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        store.workspaces.updateFleet([.init(drive: other, volumes: snapshot.volumes)]); await settle(store)
        XCTAssertTrue(runner.requiresWorkspaceReview, "Filesystem UUID/inode/birth time can survive a sector clone")
        let reattached = DriveInfo(registryEntryID: snapshot.id + 2, bsdName: "disk999997", model: snapshot.drive.model,
            serialNumber: snapshot.drive.serialNumber, firmwareRevision: "F", sizeBytes: snapshot.drive.sizeBytes,
            interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        store.workspaces.updateFleet([.init(drive: reattached, volumes: snapshot.volumes)]); await settle(store)
        XCTAssertFalse(runner.requiresWorkspaceReview, "The original serial can identify a new attachment")
    }
    @MainActor func testDuplicatePhysicalIdentityCannotClearPreviouslyUniqueReview() async throws {
        let (store, provider, snapshot) = make(), runner = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await runner.waitForCompletion()
        store.workspaces.onCompleteScan = { runner.reconcileWorkspaceReviews($0) }
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil))
        var ambiguous = snapshot; ambiguous.identityOverride = DriveIdentity.sessionIdentity(for: snapshot.drive, ambiguous: true)
        store.workspaces.updateFleet([ambiguous]); await settle(store)
        XCTAssertTrue(runner.requiresWorkspaceReview)
        store.workspaces.updateFleet([snapshot]); await settle(store)
        XCTAssertFalse(runner.requiresWorkspaceReview, "An identity change must trigger a fresh scan")
    }
    @MainActor func testBootCurrentTempScanDoesNotClearReviewFromAnotherParent() async throws {
        let (store, provider, snapshot) = make(), old = snapshot.volumes[0]
        let boot = VolumeUsage(bsdName: old.bsdName, name: "Boot fixture", mountPoint: "/", totalBytes: old.totalBytes, availableBytes: old.availableBytes,
            sharedCapacityKey: old.sharedCapacityKey, mountIdentity: old.mountIdentity, writeIdentity: old.writeIdentity, writeDirectoryIdentity: old.writeDirectoryIdentity)
        let review = MeasurementWorkspaceReview(id: UUID(), drive: snapshot.drive, volume: boot, message: "old scope", writeDirectoryPath: "/previous-custom-temp")
        var absence: Bool?
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil))
        store.workspaces.onCompleteScan = { absence = $0.confirmsAbsence(of: review) }
        store.workspaces.updateFleet([.init(drive: snapshot.drive, volumes: [boot])]); await settle(store)
        XCTAssertEqual(absence, false)
    }
    @MainActor func testCleanupReceiptWithoutCompleteFreshScanDoesNotClearReview() async throws {
        let (store, provider, snapshot) = make(), runner = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await runner.waitForCompletion()
        let id = try XCTUnwrap(runner.workspaceReviews.first?.id), name = try owned(id: id)
        store.workspaces.onCompleteScan = { runner.reconcileWorkspaceReviews($0) }
        store.workspaces.updateFleet([snapshot]); await settle(store); XCTAssertTrue(runner.requiresWorkspaceReview)
        let record = try XCTUnwrap(store.workspaces.records.first), selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        await provider.set(.init(leftovers: [], complete: false, diagnostic: "post-cleanup scan incomplete"))
        await store.workspaces.cleanup(selection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: selection.leftover.path)); XCTAssertTrue(runner.requiresWorkspaceReview)
        await provider.set(nil); store.workspaces.requestScanAll(); await settle(store); XCTAssertFalse(runner.requiresWorkspaceReview)
    }
    @MainActor func testReplacingParentAtSamePathCannotClearReviewOrUseOldConfirmation() async throws {
        let (store, _, snapshot) = make(), runner = BenchmarkRunner(store: store, worker: RecoveryFailedMeasurement())
        runner.start(snapshot: snapshot, volume: snapshot.volumes[0], config: .init(fileSizeBytes: 16384)); await runner.waitForCompletion()
        let name = try owned(id: XCTUnwrap(runner.workspaceReviews.first?.id))
        store.workspaces.onCompleteScan = { runner.reconcileWorkspaceReviews($0) }
        store.workspaces.updateFleet([snapshot]); await settle(store)
        let record = try XCTUnwrap(store.workspaces.records.first), selection = try XCTUnwrap(store.workspaces.selection(recordID: record.id, name: name))
        let archived = root.appendingPathExtension("archived"); archivedRoots.append(archived)
        try FileManager.default.moveItem(at: root, to: archived)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
        // A fresh scan against stale metadata is rejected even when empty.
        store.workspaces.requestScanAll(); await settle(store)
        XCTAssertFalse(store.workspaces.records.first?.isCurrent ?? true); XCTAssertTrue(runner.requiresWorkspaceReview)
        let old = snapshot.volumes[0]
        let replacement = VolumeUsage(bsdName: old.bsdName, name: old.name, mountPoint: old.mountPoint, totalBytes: old.totalBytes, availableBytes: old.availableBytes,
            sharedCapacityKey: old.sharedCapacityKey, mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root),
            writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        XCTAssertEqual(old.writeIdentity, replacement.writeIdentity, "same filesystem and persistent volume UUID")
        XCTAssertNotEqual(old.writeDirectoryIdentity, replacement.writeDirectoryIdentity)
        store.workspaces.updateFleet([.init(drive: snapshot.drive, volumes: [replacement])]); await settle(store)
        XCTAssertTrue(store.workspaces.records.first?.isCurrent == true)
        XCTAssertTrue(store.workspaces.records.first?.scan?.leftovers.isEmpty == true)
        XCTAssertTrue(runner.requiresWorkspaceReview, "empty replacement directory does not prove absence in original parent")
        XCTAssertFalse(store.workspaces.isCurrent(selection)); await store.workspaces.cleanup(selection)
        XCTAssertEqual(try Data(contentsOf: archived.appendingPathComponent(name).appendingPathComponent("data.bin")).count, 8192)
        XCTAssertEqual(try Data(contentsOf: archived.appendingPathComponent("outside.txt")), Data("outside".utf8))
    }
    @MainActor func testMissingParentIdentityRequiresFreshDiscoveryBeforeScanning() async throws {
        let (store, provider, snapshot) = make(), old = snapshot.volumes[0]
        let legacy = VolumeUsage(bsdName: old.bsdName, name: old.name, mountPoint: old.mountPoint, totalBytes: old.totalBytes, availableBytes: old.availableBytes,
            sharedCapacityKey: old.sharedCapacityKey, mountIdentity: old.mountIdentity, writeIdentity: old.writeIdentity)
        store.workspaces.updateFleet([.init(drive: snapshot.drive, volumes: [legacy])]); await settle(store)
        XCTAssertEqual(store.workspaces.records.first?.state, .unavailable)
        let scans = await provider.scans; XCTAssertEqual(scans, 0)
        store.workspaces.updateFleet([snapshot]); await settle(store)
        XCTAssertTrue(store.workspaces.records.first?.isCurrent == true)
    }
    @MainActor func testScanFromDifferentParentCannotPublishFreshEvidence() async throws {
        let (store, provider, snapshot) = make()
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        await provider.set(.init(leftovers: [], complete: true, diagnostic: nil, parentIdentity: WorkspaceDirectoryIdentity.capture(at: other)))
        var published = false; store.workspaces.onCompleteScan = { _ in published = true }
        store.workspaces.updateFleet([snapshot]); await settle(store)
        XCTAssertFalse(published); XCTAssertFalse(store.workspaces.records.first?.isCurrent ?? true)
        XCTAssertEqual(store.workspaces.records.first?.state, .unavailable)
    }
}
