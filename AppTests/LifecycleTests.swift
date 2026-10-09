/* Actual lifecycle/delegate, disposable SQLite and child writer fixtures. GPL-3.0-or-later. */
import XCTest
import Darwin
import AppKit
@testable import MDriveHealthCore

private actor LifecycleMeasurements: MeasurementServing {
    enum Mode { case cancel, heldCleanup, complete, cleanupError, pending }
    let mode: Mode
    private var released = false
    private(set) var entered = false, sawCancellation = false
    init(_ mode: Mode) { self.mode = mode }
    func release() { released = true }
    private func wait(cancelled: @escaping @Sendable () -> Bool, cleaning: @escaping @Sendable (Int) -> Void) async throws {
        entered = true
        if mode == .pending {
            let argv = [strdup("/bin/sleep"), strdup("0.4"), nil]; defer { for pointer in argv { free(pointer) } }
            var pid: pid_t = 0
            let status = argv.withUnsafeBufferPointer { posix_spawn(&pid, "/bin/sleep", nil, nil, $0.baseAddress, environ) }
            guard status == 0 else { throw CommandError(.launch(status)) }
            throw CommandError(.cancelled, processID: pid, pendingChild: PendingChild(processID: pid))
        }
        if mode == .complete { return }
        while !cancelled() { try await Task.sleep(for: .milliseconds(5)) }
        sawCancellation = true; cleaning(0)
        if mode == .heldCleanup { while !released { try await Task.sleep(for: .milliseconds(5)) } }
        if mode == .cleanupError { throw BenchmarkError.cleanupFailed(path: "/fixture/owned-test") }
        throw BenchmarkError.cancelled
    }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        try await wait(cancelled: cancelled, cleaning: cleaning)
        return .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), volumeBSDName: volume.bsdName, volumeName: volume.name,
                     mountPoint: volume.mountPoint, fileSizeBytes: config.fileSizeBytes, sequentialBlockBytes: config.sequentialBlockBytes,
                     randomBlockBytes: config.randomBlockBytes, queueDepth: config.queueDepth,
                     sequentialWriteBytesPerSec: 1, sequentialReadBytesPerSec: 2, randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult {
        try await wait(cancelled: cancelled, cleaning: cleaning)
        return .init(capturedAt: Date(), volumeName: volume.name, mountPoint: volume.mountPoint, bytesRequested: 8192,
                     bytesWritten: 8192, bytesVerifiedOK: 8192, firstCorruptionOffset: nil, corruptedBlocks: 0,
                     writeBytesPerSec: 1, readBytesPerSec: 2, verdict: .passedTestedRange, interruption: nil)
    }
}
@MainActor private final class LifecycleNotifications: NotificationDelivering {
    var calls = 0
    func access() async -> NotificationAccess { calls += 1; return .allowed }
    func requestPermission() async throws -> Bool { calls += 1; return true }
    func send(_ alert: DriveAlert) async throws { calls += 1 }
    func registeredRequestIDs() async -> Set<String> { [] }
}
private struct LifecycleScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}
@MainActor private final class LifecycleHarness {
    static var fixtures: [LifecycleHarness] = []
    let root: URL, store: DriveStore, monitor: MonitoringController, benchmark: BenchmarkRunner, capacity: CapacityVerifyRunner
    let backend: LifecycleMeasurements, delivery = LifecycleNotifications(), defaults: UserDefaults, suite: String
    let lifecycle: ApplicationLifecycle
    var drive: DriveInfo { .init(registryEntryID: UInt64(getpid()) << 32 | 151, bsdName: "disk999999", model: "Fixture", serialNumber: "fixture",
        firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .unsupported) }
    var volume: VolumeUsage { .init(bsdName: "disk999999s1", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
                                   sharedCapacityKey: "disk999999s1", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root)) }
    init(root: URL, mode: LifecycleMeasurements.Mode = .cancel, unavailable: Bool = false, worker: (any MeasurementServing)? = nil,
         hardware: any DriveHardwareServing = FixtureHardware(),
         loginItems: LoginItemController? = nil,
         launch: @escaping @MainActor () async throws -> Void = {}) {
        self.root = root; backend = LifecycleMeasurements(mode)
        let url = root.appendingPathComponent("history.db")
        store = DriveStore(history: HistoryAccess(factory: { if unavailable { throw HistoryError.unavailable }; return try HistoryStore(databaseURL: url) }),
                           ioScanner: LifecycleScanner(), hardware: hardware)
        suite = "lifecycle-monitor-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: SettingsKeys.monitoringEnabled)
        monitor = MonitoringController(store: store, defaults: defaults, delivery: delivery, observePreferences: false)
        benchmark = BenchmarkRunner(store: store, worker: worker ?? backend); capacity = CapacityVerifyRunner(store: store, worker: worker ?? backend)
        lifecycle = ApplicationLifecycle(store: store, monitor: monitor, benchmark: benchmark, capacity: capacity, loginItems: loginItems, launch: launch)
        Self.fixtures.append(self)
    }
    func startBenchmark() { benchmark.start(snapshot: .init(drive: drive), volume: volume, config: .init(fileSizeBytes: 16384, sequentialBlockBytes: 4096, includeRandomPhases: false)) }
    func startCapacity() { capacity.start(snapshot: .init(drive: drive), volume: volume, config: .init(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384, dataRiskAcknowledged: true)) }
    static func drain() async throws {
        let fixtures = fixtures; Self.fixtures.removeAll()
        for fixture in fixtures {
            fixture.store.beginShutdown(); fixture.monitor.beginShutdown(); fixture.benchmark.cancel(); fixture.capacity.cancel()
            await fixture.benchmark.waitForCompletion(); await fixture.capacity.waitForCompletion()
            await fixture.store.operations.waitForIdle(); await fixture.store.waitForBackgroundWork(); await fixture.monitor.shutdown()
            try await fixture.store.history.shutdown(); fixture.defaults.removePersistentDomain(forName: fixture.suite)
        }
    }
}
final class LifecycleTests: XCTestCase {
    private var root: URL!
    @MainActor func testQuitWaitsForAcceptedLoginItemChangeAndBlocksNewRequests() async throws {
        let service = LoginItemFixtureService(); service.hold = true
        let loginItems = LoginItemController(service: service)
        let h = LifecycleHarness(root: root, loginItems: loginItems)
        defer { service.release() }
        loginItems.setRequested(true); try await waitUntil { service.continuation != nil }
        var done = false
        let quit = Task { let allowed = await h.lifecycle.prepare(.quit); done = true; return allowed }
        try await waitUntil { h.lifecycle.isBusy && loginItems.isShuttingDown }
        XCTAssertFalse(done); XCTAssertTrue(loginItems.isBusy)
        loginItems.setRequested(false); XCTAssertEqual(service.requests, [true])
        service.release()
        let allowed = await quit.value
        XCTAssertTrue(allowed); XCTAssertTrue(h.lifecycle.isReady); XCTAssertEqual(loginItems.status, .enabled)
    }
    @MainActor func testFailedQuitCanResumeLoginItemControlsWithoutResubmitting() async throws {
        let service = LoginItemFixtureService(), loginItems = LoginItemController(service: service)
        let h = LifecycleHarness(root: root, loginItems: loginItems, launch: { throw HistoryError.unavailable })
        let allowed = await h.lifecycle.prepare(.relaunch)
        XCTAssertFalse(allowed); XCTAssertTrue(loginItems.isShuttingDown)
        await h.lifecycle.resume()
        XCTAssertFalse(loginItems.isShuttingDown); XCTAssertTrue(service.requests.isEmpty)
        loginItems.setRequested(true); await loginItems.waitForCompletion()
        XCTAssertEqual(loginItems.status, .enabled); XCTAssertEqual(service.requests, [true])
    }
    override func setUpWithError() throws {
        if let path = ProcessInfo.processInfo.environment["MDRIVE_LIFECYCLE_CHILD_ROOT"] { root = URL(fileURLWithPath: path); return }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mdrive-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDown() async throws {
        if ProcessInfo.processInfo.environment["MDRIVE_LIFECYCLE_CHILD_ROOT"] == nil {
            try await LifecycleHarness.drain()
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("outside".utf8))
            try FileManager.default.removeItem(at: root)
        }
        try await super.tearDown()
    }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("lifecycle fixture did not reach expected state"); throw HistoryError.unavailable
    }
    @MainActor private func waitForBackend(_ backend: LifecycleMeasurements) async throws {
        for _ in 0..<1000 { if await backend.entered { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("measurement backend never entered"); throw HistoryError.unavailable
    }
    @MainActor private func waitForChild(_ h: LifecycleHarness) async throws {
        for _ in 0..<1500 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("worker-ready").path) { return }
            if case .failed(let message) = h.benchmark.state { XCTFail(message); throw HistoryError.unavailable }
            if case .failed(let message) = h.capacity.state { XCTFail(message); throw HistoryError.unavailable }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("child did not reach handshake"); throw HistoryError.unavailable
    }
    @MainActor func testQuitWaitsForCleanupAndBlocksEveryNewOperationWithoutBlockingUI() async throws {
        let h = LifecycleHarness(root: root, mode: .heldCleanup); h.startBenchmark(); try await waitForBackend(h.backend)
        var done = false
        let quit = Task { let allowed = await h.lifecycle.prepare(.quit); done = true; return allowed }
        try await waitUntil { h.benchmark.isCleaning }
        XCTAssertTrue(h.benchmark.isCancelling); XCTAssertFalse(done); XCTAssertTrue(h.store.benchmarkInProgress)
        for kind in [DriveOperationKind.benchmark, .capacity, .probe, .selfTestStart, .eject, .memory, .kernelLog] {
            XCTAssertThrowsError(try h.store.operations.begin(driveID: h.drive.id, kind: kind))
        }
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: h.drive.id))
        await h.backend.release(); let allowed = await quit.value
        XCTAssertTrue(allowed); XCTAssertTrue(h.lifecycle.isReady); XCTAssertEqual(h.store.history.state, .closed)
        XCTAssertFalse(h.store.benchmarkInProgress); XCTAssertFalse(h.benchmark.isCleaning)
        XCTAssertEqual(h.delivery.calls, 0)
    }
    @MainActor func testCapacityQuitUsesSameCoordinatedCancellation() async throws {
        let h = LifecycleHarness(root: root); h.startCapacity(); try await waitForBackend(h.backend)
        let allowed = await h.lifecycle.prepare(.quit)
        XCTAssertTrue(allowed); XCTAssertFalse(h.capacity.isRunning); XCTAssertFalse(h.store.benchmarkInProgress)
        let cancelled = await h.backend.sawCancellation; XCTAssertTrue(cancelled)
    }
    @MainActor func testUnsavedResultPreventsQuitAndResumeKeepsResultAvailable() async throws {
        let h = LifecycleHarness(root: root, mode: .complete, unavailable: true); h.startBenchmark()
        try await waitUntil { !h.benchmark.isRunning && !h.benchmark.isSaving && !h.benchmark.unsavedResults.isEmpty }
        let id = h.benchmark.unsavedResults[0].id
        let allowed = await h.lifecycle.prepare(.quit)
        XCTAssertFalse(allowed); XCTAssertNotNil(h.lifecycle.failure); XCTAssertFalse(h.lifecycle.isReady)
        XCTAssertEqual(h.benchmark.unsavedResults[0].id, id)
        await h.lifecycle.resume(); XCTAssertNil(h.lifecycle.failure); XCTAssertFalse(h.store.operations.isShuttingDown)
        XCTAssertEqual(h.benchmark.unsavedResults[0].id, id)
    }
    @MainActor func testSuccessfulPendingSaveFinishesBeforeConnectionClose() async throws {
        let h = LifecycleHarness(root: root, mode: .complete); h.startBenchmark()
        try await waitUntil { !h.benchmark.isRunning && !h.benchmark.isSaving }
        let key = DriveSnapshot(drive: h.drive).identity.key
        let allowed = await h.lifecycle.prepare(.quit); XCTAssertTrue(allowed)
        let check = try HistoryStore(databaseURL: root.appendingPathComponent("history.db")); defer { try? check.close() }
        let saved = try await check.benchmarks(driveKey: key, since: .distantPast)
        XCTAssertEqual(saved.count, 1)
    }
    @MainActor func testCleanupFailureAndResetRetainRunMetadataAndBlockQuit() async throws {
        let h = LifecycleHarness(root: root, mode: .cleanupError); h.startBenchmark(); try await waitForBackend(h.backend)
        let id = try XCTUnwrap(h.benchmark.measurementID)
        let allowed = await h.lifecycle.prepare(.quit); XCTAssertFalse(allowed)
        h.benchmark.reset(); XCTAssertTrue(h.benchmark.requiresWorkspaceReview)
        XCTAssertEqual(h.benchmark.workspaceReviews.first?.id, id); XCTAssertEqual(h.benchmark.workspaceReviews.first?.volume, h.volume)
        XCTAssertTrue(h.lifecycle.failure?.contains(id.uuidString) == true)
    }
    @MainActor func testUnreapedChildRetainsLockAndCannotConfirmCleanQuit() async throws {
        let h = LifecycleHarness(root: root, mode: .pending); h.startBenchmark()
        try await waitUntil { !h.benchmark.isRunning }
        let quit = Task { await h.lifecycle.prepare(.quit) }
        try await waitUntil { h.lifecycle.isBusy }
        XCTAssertTrue(h.store.benchmarkInProgress); XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: h.drive.id))
        let allowed = await quit.value; XCTAssertFalse(allowed); XCTAssertFalse(h.store.benchmarkInProgress)
        XCTAssertTrue(h.benchmark.requiresWorkspaceReview)
    }
    @MainActor func testRelaunchFailureCanResumeWithoutOpeningAnInstanceEarly() async throws {
        var launches = 0
        let h = LifecycleHarness(root: root, launch: { launches += 1; throw CocoaError(.executableNotLoadable) })
        let allowed = await h.lifecycle.prepare(.relaunch)
        XCTAssertFalse(allowed); XCTAssertEqual(launches, 1); XCTAssertEqual(h.store.history.state, .closed)
        await h.lifecycle.resume(); XCTAssertFalse(h.store.operations.isShuttingDown)
        try await h.store.history.connect(); XCTAssertEqual(h.store.history.state, .ready)
    }
    @MainActor func testConcurrentRelaunchRequestsShareOneShutdownAndOneLaunch() async throws {
        var launches = 0
        let h = LifecycleHarness(root: root, mode: .heldCleanup, launch: { launches += 1 })
        h.startBenchmark(); try await waitForBackend(h.backend)
        let first = Task { await h.lifecycle.prepare(.relaunch) }, second = Task { await h.lifecycle.prepare(.relaunch) }
        try await waitUntil { h.benchmark.isCleaning }; XCTAssertEqual(launches, 0)
        await h.backend.release(); let a = await first.value, b = await second.value
        XCTAssertTrue(a && b); XCTAssertEqual(launches, 1)
    }
    @MainActor func testQuitWaitsForFleetRefreshAndItsBackgroundPersistence() async throws {
        let drive = DriveInfo(registryEntryID: UInt64(getpid()) << 32 | 152, bsdName: "disk999998", model: "Fixture", serialNumber: "refresh-fixture",
            firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
        let hardware = FixtureHardware(drives: [drive], heldDrive: drive.id)
        let h = LifecycleHarness(root: root, hardware: hardware)
        let refresh = Task { await h.store.refresh() }
        try await waitUntil { h.store.snapshots.first?.isProbing == true }
        var allowed: Bool?
        let quit = Task { allowed = await h.lifecycle.prepare(.quit) }
        try await waitUntil { h.lifecycle.isBusy }; XCTAssertNil(allowed)
        await hardware.release(); await refresh.value; await quit.value
        XCTAssertEqual(allowed, true); XCTAssertEqual(h.store.history.state, .closed)
        XCTAssertFalse(h.store.isRefreshing); XCTAssertTrue(h.store.operations.leases.isEmpty)
    }
    @MainActor func testSparkleInstallationWaitsForCleanupAndDoesNotLaunchOldInstance() async throws {
        var launches = 0, installs = 0
        let h = LifecycleHarness(root: root, mode: .heldCleanup, launch: { launches += 1 })
        let delegate = AppDelegate()
        delegate.configure(h.lifecycle); delegate.statusPresented = { _ in }
        h.startBenchmark(); try await waitForBackend(h.backend)
        delegate.prepareForUpdate { installs += 1 }
        try await waitUntil { h.benchmark.isCleaning }
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await h.backend.release()
        try await waitUntil { installs == 1 }
        XCTAssertTrue(h.lifecycle.isReady); XCTAssertEqual(launches, 0)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
    @MainActor func testSparkleInstallationRemainsPendingOnCleanupFailure() async throws {
        var installs = 0, terminations = 0
        let h = LifecycleHarness(root: root, mode: .cleanupError), delegate = AppDelegate()
        delegate.configure(h.lifecycle); delegate.statusPresented = { _ in }
        delegate.terminateRequested = { terminations += 1 }
        h.startBenchmark(); try await waitForBackend(h.backend)
        delegate.prepareForUpdate { installs += 1 }
        try await waitUntil { h.lifecycle.failure != nil }
        XCTAssertEqual(installs, 0)
        h.lifecycle.retry()
        try await waitUntil { h.lifecycle.failure != nil && !h.lifecycle.isBusy }
        XCTAssertEqual(installs, 0); XCTAssertEqual(terminations, 0)
    }
    @MainActor func testNativeDelegateDefersReplyAndCoalescesRepeatedQuitRequests() async throws {
        let h = LifecycleHarness(root: root, mode: .heldCleanup), delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.configure(h.lifecycle); delegate.terminationReply = { replies.append($0) }; delegate.statusPresented = { _ in }
        h.startBenchmark(); try await waitForBackend(h.backend)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(h.store.operations.isShuttingDown, "native delegate must close admissions before returning terminateLater")
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        try await waitUntil { h.benchmark.isCleaning }; XCTAssertTrue(replies.isEmpty)
        await h.backend.release(); try await waitUntil { !replies.isEmpty }
        XCTAssertEqual(replies, [true]); XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
    }
    @MainActor func testSettingsRelaunchUsesDelegateAndFailedQuitRepliesFalse() async throws {
        let h = LifecycleHarness(root: root, mode: .complete, unavailable: true), delegate = AppDelegate()
        var requests = 0, replies: [Bool] = []
        delegate.configure(h.lifecycle); delegate.terminateRequested = { requests += 1 }; delegate.terminationReply = { replies.append($0) }
        delegate.statusPresented = { _ in }
        h.startBenchmark(); try await waitUntil { !h.benchmark.isRunning && !h.benchmark.isSaving }
        h.lifecycle.requestRelaunch(); XCTAssertEqual(requests, 1)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        try await waitUntil { !replies.isEmpty }; XCTAssertEqual(replies, [false])
        XCTAssertEqual(h.lifecycle.kind, .relaunch); XCTAssertFalse(h.benchmark.unsavedResults.isEmpty)
    }
    private func childWorker() throws -> SystemMeasurements {
        let runner = String(decoding: try BoundedProcess.run(ProcessCommand("/usr/bin/xcrun", ["--sdk", "macosx", "--find", "xctest"], timeout: 5)).requireSuccess(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // A fresh xctest host must not join the parent's Xcode test session
        // or inherit its bundle-injection library. Keep loader search paths.
        let injected = ProcessInfo.processInfo.environment.keys.filter {
            $0.hasPrefix("XCTest") || $0.hasPrefix("XCInject") || $0 == "DYLD_INSERT_LIBRARIES"
        }.sorted().flatMap { ["-u", $0] }
        let arguments = ["-c", "exec 4>&1; exec \"$@\" 1>&2", "lifecycle-child", "/usr/bin/env"] + injected
            + ["MDRIVE_LIFECYCLE_CHILD_ROOT=\(root.path)", runner, "-XCTest", "MDriveHealthModelTests.LifecycleTests/testLifecycleWorkerFixtureChild", Bundle(for: Self.self).bundlePath]
        return SystemMeasurements(client: .init(executable: "/bin/sh", arguments: arguments, idleTimeout: 3, timeout: 20, terminateGrace: 1, journalRootURL: root.appendingPathComponent("journal")))
    }
    func testLifecycleWorkerFixtureChild() throws {
        guard ProcessInfo.processInfo.environment["MDRIVE_LIFECYCLE_CHILD_ROOT"] != nil else { return }
        let root = root!
        let status = MeasurementWorker.serve(output: FileHandle(fileDescriptor: 4, closeOnDealloc: false)) { request, cancelled, progress, capacityProgress, cleaning in
            try DriveCommandLock.validateDelegation(registryEntryID: request.drive.id, token: request.lockToken)
            let ready: @Sendable () -> Void = { try! Data(String(getpid()).utf8).write(to: root.appendingPathComponent("worker-ready"), options: .atomic) }
            switch request.operation {
            case .benchmark(let config):
                return .benchmarkResult(try DiskBenchmarkEngine().run(in: root, volume: request.volume, config: config, isCancelled: cancelled,
                    progress: { value in progress(value); if value.phase == .sequentialWrite && value.processedBytes == 0 { ready(); while !cancelled() { Thread.sleep(forTimeInterval: 0.01) } } },
                    measurementID: request.id, cleanupProgress: cleaning))
            case .capacity(let config):
                var io = CapacityFileIO()
                io.write = { fd, pointer, count, offset in let n = pwrite(fd, pointer, count, offset); ready(); while !cancelled() { Thread.sleep(forTimeInterval: 0.01) }; return n }
                return .capacityResult(try CapacityVerifier(io: io).run(in: root, volume: request.volume, config: config, isCancelled: cancelled,
                    progress: capacityProgress, measurementID: request.id, cleanupProgress: cleaning))
            }
        }
        exit(status)
    }
    @MainActor func testQuitCancelsActualChildCapacityAndConfirmsOwnedCleanup() async throws {
        let h = LifecycleHarness(root: root, worker: try childWorker()); h.startCapacity()
        try await waitForChild(h)
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("worker-ready"), encoding: .utf8)))
        XCTAssertThrowsError(try DiskWorkspaceRecovery.scanFixture(at: root))
        let allowed = await h.lifecycle.prepare(.quit); XCTAssertTrue(allowed)
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
        XCTAssertFalse(h.capacity.requiresWorkspaceReview)
    }
    @MainActor func testRelaunchClosesSQLiteAndActualChildBenchmarkBeforeLaunchCallback() async throws {
        var launches = 0; let root = root!
        var history: HistoryAccess?, childPID: pid_t?
        let h = LifecycleHarness(root: root, worker: try childWorker(), launch: {
            XCTAssertEqual(history?.state, .closed)
            if let childPID { XCTAssertEqual(kill(childPID, 0), -1); XCTAssertEqual(errno, ESRCH) }
            XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
            let databasePath = root.appendingPathComponent("history.db").resolvingSymlinksInPath().path
            var openDatabaseFiles = 0, buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            for fd in 0..<min(getdtablesize(), 4096) where fcntl(fd, F_GETPATH, &buffer) == 0 {
                if String(cString: buffer).hasPrefix(databasePath) { openDatabaseFiles += 1 }
            }
            XCTAssertEqual(openDatabaseFiles, 0, "new instance cannot launch while an old SQLite handle is still open")
            launches += 1
        })
        history = h.store.history
        try await h.store.history.connect(); h.startBenchmark()
        try await waitForChild(h)
        let pid = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("worker-ready"), encoding: .utf8)))
        childPID = pid
        let allowed = await h.lifecycle.prepare(.relaunch)
        XCTAssertTrue(allowed); XCTAssertEqual(launches, 1); XCTAssertEqual(h.store.history.state, .closed)
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
}
