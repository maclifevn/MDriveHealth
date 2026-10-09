/* Actual child writer/cancellation/crash fixtures. GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

private final class MeasurementFlag: @unchecked Sendable {
    private let lock = NSLock(); private var set = false
    func trip() { lock.lock(); set = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return set }
}
// Own exactly one PID and reap it directly. Foundation Process.waitUntilExit
// was observed stuck in a CFRunLoop after its SIGKILLed fixture had disappeared.
private final class MeasurementFixtureParent {
    let pid: pid_t
    private var reaped = false
    init(arguments: [String], stderr: FileHandle? = nil) throws {
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        func checked(_ code: Int32) throws { if code != 0 { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) } }
        try checked(posix_spawn_file_actions_init(&actions)); defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes)); defer { posix_spawnattr_destroy(&attributes) }
        let nullFD = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(nullFD) }
        for (source, target) in [(nullFD, STDIN_FILENO), (nullFD, STDOUT_FILENO), (stderr?.fileDescriptor ?? nullFD, STDERR_FILENO)] {
            try checked(posix_spawn_file_actions_adddup2(&actions, source, target))
        }
        var mask = sigset_t(), defaults = sigset_t(); sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM, SIGINT, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        try checked(posix_spawnattr_setsigmask(&attributes, &mask)); try checked(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        let argv = (["/bin/sh"] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        var child: pid_t = 0
        try argv.withUnsafeBufferPointer { try checked(posix_spawn(&child, "/bin/sh", &actions, &attributes, $0.baseAddress, environ)) }
        pid = child
    }
    func killAndReap() throws {
        guard !reaped else { return } // Never signal a PID again after it can be reused.
        if kill(pid, SIGKILL) != 0, errno != ESRCH { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true; return }
            if result < 0, errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if ContinuousClock.now >= deadline { throw WorkspaceRecoveryError.unsafe("Fixture parent SIGKILL exit was not confirmed") }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
final class MeasurementWorkerTests: XCTestCase {
    private var root: URL!
    private var driveID: UInt64 {
        UInt64(ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_DRIVE"] ?? "") ?? (UInt64(getpid()) << 32 | 101)
    }
    private var drive: DriveInfo { .init(registryEntryID: driveID, bsdName: "disk999999", model: "Fixture", serialNumber: "fixture", firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .unsupported) }
    private var volume: VolumeUsage { .init(bsdName: "disk999999s1", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
                                           sharedCapacityKey: "disk999999s1", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root)) }
    private var benchmark: BenchmarkConfig { .init(fileSizeBytes: 16384, sequentialBlockBytes: 4096, includeRandomPhases: false) }
    private var capacity: CapacityVerifyConfig { .init(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384, dataRiskAcknowledged: true) }
    override func setUpWithError() throws {
        if let path = ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_ROOT"] { root = URL(fileURLWithPath: path); return }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mdrive-measurement-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("keep".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_ROOT"] == nil {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("keep".utf8))
            try FileManager.default.removeItem(at: root)
        }
    }
    private func hostArguments(role: String, mode: String, id: UUID) throws -> [String] {
        let bytes = try BoundedProcess.run(ProcessCommand("/usr/bin/xcrun", ["--find","xctest"], timeout: 5, scope: "measurement-test-runner")).requireSuccess()
        let runner = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var environment = ["MDRIVE_MEASUREMENT_FIXTURE_ROOT=\(root.path)", "MDRIVE_MEASUREMENT_FIXTURE_ROLE=\(role)", "MDRIVE_MEASUREMENT_FIXTURE_MODE=\(mode)", "MDRIVE_MEASUREMENT_FIXTURE_ID=\(id.uuidString)", "MDRIVE_MEASUREMENT_FIXTURE_DRIVE=\(driveID)"]
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") {
            var location = Dl_info()
            if dladdr(symbol, &location) != 0, let filename = location.dli_fname { environment.append("DYLD_INSERT_LIBRARIES=\(String(cString: filename))") }
        }
        let method = role == "parent" ? "testParentFixtureChild" : "testWorkerFixtureChild"
        // XCTest diagnostics go to stderr; protocol owns only FD 4, copied
        // from stdout before that redirection. Arguments remain literal argv.
        return ["-c", "exec 4>&1; exec \"$@\" 1>&2", "measurement-fixture", "/usr/bin/env"] + environment
            + [runner,"-XCTest","MDriveHealthCoreTests.MeasurementWorkerTests/\(method)",Bundle(for: Self.self).bundlePath]
    }
    private func client(_ mode: String = "normal", id: UUID = UUID(), idle: TimeInterval = 3, grace: TimeInterval = 1) throws -> MeasurementWorkerClient {
        .init(executable: "/bin/sh", arguments: try hostArguments(role: "worker", mode: mode, id: id), idleTimeout: idle, timeout: 20, terminateGrace: grace, journalRootURL: root.appendingPathComponent("journal"))
    }
    private func waitForReady() async throws -> Int32 {
        let file = root.appendingPathComponent("worker-ready"), deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: file.path) {
            if Date() >= deadline { throw WorkspaceRecoveryError.unsafe("worker fixture never reached handshake") }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(Int32(String(contentsOf: file, encoding: .utf8)))
    }
    private func ready() throws { try Data(String(getpid()).utf8).write(to: root.appendingPathComponent("worker-ready"), options: .atomic) }
    func testWorkerFixtureChild() throws {
        guard ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_ROLE"] == "worker" else { return }
        let mode = ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_MODE"] ?? "normal"
        let status = MeasurementWorker.serve(output: FileHandle(fileDescriptor: 4, closeOnDealloc: false), requireJournal: true, afterJournal: { _, cancelled in
            if mode == "pause-after-journal" { try! self.ready(); while !cancelled() { Thread.sleep(forTimeInterval: 0.01) } }
        }) { request, cancelled, progress, capacityProgress, cleaning in
            try DriveCommandLock.validateDelegation(registryEntryID: request.drive.id, token: request.lockToken)
            if mode == "storage-failure" {
                let fd = openat(5, "terminal.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(.EIO) }; defer { close(fd) }
                let bytes = Data("preserve-user-record".utf8)
                XCTAssertEqual(bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }, bytes.count); XCTAssertEqual(fsync(fd), 0)
            }
            if mode == "stall" {
                let workspace = try DiskTestWorkspace.fixture(at: self.root, sessionID: request.id, cleanupProgress: cleaning)
                let fd = try workspace.createFile("stalled.bin")
                let data = [UInt8](repeating: 0xA5, count: 4096)
                XCTAssertEqual(data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }, data.count)
                try self.ready()
                // A deliberately unreturned fixture call, not a kernel stall.
                withExtendedLifetime(workspace) { while true { Thread.sleep(forTimeInterval: 0.05) } }
            }
            if mode == "cleanup-error" {
                let workspace = try DiskTestWorkspace.fixture(at: self.root, sessionID: request.id, cleanupProgress: cleaning)
                let fd = try workspace.createFile("data.bin"); close(fd)
                try Data("unknown".utf8).write(to: workspace.directoryURL.appendingPathComponent("unrecorded.txt"))
                try self.ready()
                while !cancelled() { Thread.sleep(forTimeInterval: 0.01) }
                return try workspace.withCleanup { throw BenchmarkError.cancelled }
            }
            switch request.operation {
            case .benchmark(let config):
                let handler: DiskBenchmarkEngine.ProgressHandler = { p in
                    progress(p)
                    if mode == "cancel" && p.phase == .sequentialWrite && p.processedBytes == 0 {
                        try! self.ready()
                        while !cancelled() { Thread.sleep(forTimeInterval: 0.01) }
                    }
                }
                let result = try DiskBenchmarkEngine().run(in: self.root, volume: request.volume, config: config,
                    isCancelled: cancelled, progress: handler, measurementID: request.id, cleanupProgress: cleaning)
                if mode == "broken-output" { close(4) }
                return .benchmarkResult(result)
            case .capacity(let config):
                var io = CapacityFileIO()
                if mode == "cancel" {
                    io.write = { fd, pointer, count, offset in
                        let n = pwrite(fd, pointer, count, offset)
                        try! self.ready()
                        while !cancelled() { Thread.sleep(forTimeInterval: 0.01) }
                        return n
                    }
                }
                if mode == "corrupt" {
                    io.read = { fd, pointer, count, offset in
                        let n = pread(fd, pointer, count, offset)
                        if n > 0 { pointer.assumingMemoryBound(to: UInt8.self).pointee ^= 1 }
                        return n
                    }
                }
                if mode == "short-write" {
                    io.write = { fd, pointer, count, offset in pwrite(fd, pointer, count / 2, offset) }
                }
                return .capacityResult(try CapacityVerifier(io: io).run(in: self.root, volume: request.volume, config: config,
                    isCancelled: cancelled, progress: capacityProgress, measurementID: request.id, cleanupProgress: cleaning))
            }
        }
        exit(status)
    }
    func testParentFixtureChild() throws {
        guard ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_ROLE"] == "parent" else { return }
        let id = UUID(uuidString: ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_ID"]!)!
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID)
        let mode = ProcessInfo.processInfo.environment["MDRIVE_MEASUREMENT_FIXTURE_MODE"] ?? "stall"
        _ = try client(mode, id: id, idle: 120, grace: 10).benchmarkBlocking(drive: drive, volume: volume, config: benchmark, id: id, lease: lease)
        XCTFail("parent must be killed while writer is still stalled")
    }
    func testActualChildBenchmarkProducesBoundResultAfterOwnedCleanup() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let received = MeasurementFlag(), clean = MeasurementFlag(), id = UUID()
        let result = try await client(id: id).benchmark(drive: drive, volume: volume, config: benchmark, id: id, lease: lease,
            progress: { if $0.processedBytes > 0 { received.trip() } }, cleaning: { _ in clean.trip() })
        XCTAssertEqual(result.fileSizeBytes, 16384); XCTAssertEqual(result.volumeBSDName, volume.bsdName)
        XCTAssertTrue(received.value); XCTAssertTrue(clean.value)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualChildStorageFailurePreservesCompletedResultAndForeignMetadata() async throws {
        let id = UUID(), lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        do {
            _ = try await client("storage-failure", id: id).benchmark(drive: drive, volume: volume, config: benchmark, id: id, lease: lease)
            XCTFail("The unknown terminal file cannot be overwritten")
        } catch let error as MeasurementWorkerError {
            guard case .resultNotPersisted(let record, _) = error, case .benchmark(let result) = record.terminal?.outcome else { return XCTFail("\(error)") }
            XCTAssertEqual(record.id, id); XCTAssertEqual(result.fileSizeBytes, 16384); XCTAssertTrue(record.terminal!.outcome.cleanupConfirmed)
            let history = try HistoryStore(databaseURL: root.appendingPathComponent("history.db")); defer { try? history.close() }
            let receipt = try await history.recordMeasurement(record)
            let journal = try MeasurementJournal(rootURL: root.appendingPathComponent("journal"))
            XCTAssertThrowsError(try journal.discardCommitted(receipt))
            let rows = try await history.benchmarks(driveKey: record.intent.driveKey, since: .distantPast); XCTAssertEqual(rows.count, 1)
        }
        let path = root.appendingPathComponent("journal/job-" + id.uuidString + "/terminal.json")
        XCTAssertEqual(try Data(contentsOf: path), Data("preserve-user-record".utf8))
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualBrokenOutputRestoresDurableResultAfterExit() async throws {
        let id = UUID(), lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        do {
            _ = try await client("broken-output", id: id).benchmark(drive: drive, volume: volume, config: benchmark, id: id, lease: lease)
            XCTFail("Closed result IPC must be reported")
        } catch let error as MeasurementWorkerError {
            guard case .resultNotDelivered(let record, _) = error, case .benchmark(let result) = record.terminal?.outcome else { return XCTFail("\(error)") }
            XCTAssertEqual(record.id, id); XCTAssertEqual(result.fileSizeBytes, 16384)
            let restored = try XCTUnwrap(MeasurementJournal(rootURL: root.appendingPathComponent("journal")).scan().jobs.first)
            XCTAssertEqual(restored.state, .completed); let restoredHash = try restored.record?.recordSHA256, expectedHash = try record.recordSHA256; XCTAssertEqual(restoredHash, expectedHash)
        }
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testWrongTicketIsRejectedInActualChildBeforeCreatingWorkspace() async throws {
        let id = UUID(), lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let journal = try MeasurementJournal(rootURL: root.appendingPathComponent("journal"))
        let job = try journal.prepare(.init(id: id, drive: drive, driveKey: "fixture", volume: volume, operation: .benchmark(benchmark)))
        let wrong = MeasurementJobTicket(version: 1, id: id, nonce: UUID(), directory: job.ticket.directory, intentSHA256: job.ticket.intentSHA256)
        let request = MeasurementRequest(id: id, drive: drive, volume: volume, lockToken: lease.token, operation: .benchmark(benchmark), job: wrong)
        var command = ProcessCommand("/bin/sh", try hostArguments(role: "worker", mode: "normal", id: id), timeout: 5, scope: "wrong-job-\(id)")
        command.input = try JSONEncoder().encode(request); command.inheritedFileDescriptors = [3: try lease.delegatedFD(), 5: try job.delegatedFD()]
        let output = try await BoundedProcess.run(command)
        XCTAssertFalse(output.termination.succeeded); XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertNil(try job.record().terminal); XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testProductionWorkerRequiresJournalBeforeDataIO() async throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mdrivehealth-worker")
        var command = ProcessCommand(executable.path, ["--measurement-worker"], timeout: 5, scope: "no-job-\(UUID())")
        command.input = try JSONEncoder().encode(request())
        let output = try await BoundedProcess.run(command)
        XCTAssertFalse(output.termination.succeeded); XCTAssertTrue(output.stdout.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["outside.txt"])
    }
    func testParentDeathAfterTerminalPublicationRestoresCompletedResult() async throws {
        let id = UUID(), parent = try MeasurementFixtureParent(arguments: hostArguments(role: "parent", mode: "pause-after-journal", id: id))
        defer { do { try parent.killAndReap() } catch { XCTFail("Fixture parent teardown: \(error)") } }
        let child = try await waitForReady(), journal = try MeasurementJournal(rootURL: root.appendingPathComponent("journal"))
        XCTAssertEqual(try journal.scan().jobs.first?.state, .active)
        try parent.killAndReap()
        let deadline = Date().addingTimeInterval(15)
        while kill(child, 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(kill(child, 0), -1); XCTAssertEqual(errno, ESRCH)
        let recovered = try XCTUnwrap(journal.scan().jobs.first)
        XCTAssertEqual(recovered.state, .completed); XCTAssertEqual(recovered.record?.id, id)
        guard case .benchmark(let result) = recovered.record?.terminal?.outcome else { return XCTFail("Completed result disappeared") }
        XCTAssertEqual(result.fileSizeBytes, 16384); XCTAssertTrue(recovered.cleanupConfirmed)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualChildCapacityVerifiesOnlyRequestedRangeAndCleans() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let result = try await client().capacity(drive: drive, volume: volume, config: capacity, lease: lease)
        XCTAssertEqual(result.verdict, .passedTestedRange); XCTAssertEqual(result.bytesRequested, 16384); XCTAssertEqual(result.bytesVerifiedOK, 16384)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualChildRandomPhasesAtQD1AndQD8ProduceBoundResults() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        for depth in [1, 8] {
            let config = BenchmarkConfig(fileSizeBytes: 32768, sequentialBlockBytes: 4096,
                                         includeRandomPhases: true, randomPhaseSeconds: 0.02, queueDepth: depth)
            let result = try await client().benchmark(drive: drive, volume: volume, config: config, lease: lease)
            XCTAssertEqual(result.queueDepth, depth); XCTAssertNotNil(result.randomWriteBytesPerSec); XCTAssertNotNil(result.randomReadBytesPerSec)
            XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
        }
    }
    func testBlockingCLIClientRunsBothOwnedEnginesInChild() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let worker = try client(), drive = drive, volume = volume, benchmark = benchmark, capacity = capacity
        let results = try await Task.detached {
            let speed = try worker.benchmarkBlocking(drive: drive, volume: volume, config: benchmark, lease: lease)
            let verified = try worker.capacityBlocking(drive: drive, volume: volume, config: capacity, lease: lease)
            return (speed, verified)
        }.value
        XCTAssertEqual(results.0.fileSizeBytes, 16384); XCTAssertEqual(results.1.verdict, .passedTestedRange)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testBenchmarkCancellationWaitsForCooperativeCleanupAndActualExit() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let flag = MeasurementFlag(), worker = try client("cancel")
        let work = Task { try await worker.benchmark(drive: drive, volume: volume, config: benchmark, lease: lease, isCancelled: { flag.value }) }
        let pid = try await waitForReady(); defer { work.cancel() }
        XCTAssertThrowsError(try DiskWorkspaceRecovery.scanFixture(at: root))
        flag.trip()
        do { _ = try await work.value; XCTFail("must cancel") }
        catch { XCTAssertEqual(error as? BenchmarkError, .cancelled) }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualChildCorruptionResultSurvivesProtocolWithoutBecomingPass() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let result = try await client("corrupt").capacity(drive: drive, volume: volume, config: capacity, lease: lease)
        XCTAssertEqual(result.verdict, .dataCorrupted); XCTAssertEqual(result.bytesRequested, 16384)
        XCTAssertEqual(result.bytesVerifiedOK, 0); XCTAssertEqual(result.corruptedBlocks, 4); XCTAssertEqual(result.firstCorruptionOffset, 0)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualChildShortWriteIsInconclusiveAndOwnedFileIsCleaned() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let result = try await client("short-write").capacity(drive: drive, volume: volume, config: capacity, lease: lease)
        XCTAssertEqual(result.verdict, .inconclusive); XCTAssertEqual(result.interruption, .shortWrite)
        XCTAssertEqual(result.bytesWritten, 2048); XCTAssertEqual(result.bytesRequested, 16384)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testCapacityCancellationRunsOwnedCleanup() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let worker = try client("cancel")
        let work = Task { try await worker.capacity(drive: drive, volume: volume, config: capacity, lease: lease) }
        let pid = try await waitForReady(); work.cancel()
        do { _ = try await work.value; XCTFail("must cancel") } catch { XCTAssertEqual(error as? BenchmarkError, .cancelled) }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testCancellationDoesNotHideCleanupFailureOrDeleteUnknownFile() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let worker = try client("cleanup-error")
        let work = Task { try await worker.benchmark(drive: drive, volume: volume, config: benchmark, lease: lease) }
        _ = try await waitForReady(); work.cancel()
        do { _ = try await work.value; XCTFail("must report cleanup error") }
        catch { XCTAssertTrue(error.localizedDescription.contains(WorkspaceJournal.prefix), "\(error)") }
        let leftovers = try DiskWorkspaceRecovery.scanFixture(at: root).leftovers
        XCTAssertEqual(leftovers.count, 1); XCTAssertEqual(leftovers.first?.status, .unverified)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: leftovers[0].path).appendingPathComponent("unrecorded.txt")), Data("unknown".utf8))
    }
    func testStalledChildIsKilledReapedAndOwnedFilesRemainRecoverable() async throws {
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let worker = try client("stall", idle: 0.8, grace: 0.1)
        let work = Task { try await worker.benchmark(drive: drive, volume: volume, config: benchmark, lease: lease) }
        let pid = try await waitForReady()
        do { _ = try await work.value; XCTFail("stalled call must fail") }
        catch let error as CommandError { XCTAssertEqual(error.reason, .idleTimedOut); if let pending = error.pendingChild { await pending.waitForExit() } }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        let leftovers = try DiskWorkspaceRecovery.scanFixture(at: root).leftovers
        XCTAssertEqual(leftovers.count, 1); XCTAssertEqual(leftovers[0].status, .recoverable); XCTAssertEqual(leftovers[0].bytes, 4096)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: leftovers[0])
    }
    func testParentDeathRetainsDeviceLeaseUntilGuardianStopsChild() async throws {
        let id = UUID()
        let diagnostic = root.appendingPathComponent("parent-fixture.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: diagnostic.path, contents: nil))
        let log = try FileHandle(forWritingTo: diagnostic); defer { try? log.close() }
        let parent = try MeasurementFixtureParent(arguments: hostArguments(role: "parent", mode: "stall", id: id), stderr: log)
        defer { do { try parent.killAndReap() } catch { XCTFail("Fixture parent teardown: \(error)") } }
        let childPID: pid_t
        do { childPID = try await waitForReady() }
        catch {
            let text = (try? String(contentsOf: diagnostic, encoding: .utf8)) ?? "missing parent diagnostics"
            XCTFail(String(text.suffix(4096))); throw error
        }
        try parent.killAndReap()
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: driveID), "child's delegated open-file description must retain ownership")
        let journal = try MeasurementJournal(rootURL: root.appendingPathComponent("journal"))
        XCTAssertEqual(try journal.scan().jobs.first?.state, .active)
        XCTAssertThrowsError(try journal.openJob(id: id), "The child also owns the actual delegated job OFD")
        let deadline = Date().addingTimeInterval(15)
        while kill(childPID, 0) == 0 && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(kill(childPID, 0), -1); XCTAssertEqual(errno, ESRCH)
        let next = try DriveCommandLock.acquire(registryEntryID: driveID); next.release()
        let recovered = try XCTUnwrap(journal.scan().jobs.first)
        XCTAssertEqual(recovered.state, .interrupted); XCTAssertEqual(recovered.record?.id, id)
        let found = try DiskWorkspaceRecovery.scanFixture(at: root).leftovers
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found[0].name, WorkspaceJournal.prefix + id.uuidString); XCTAssertEqual(found[0].status, .recoverable)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found[0])
    }
    func testForcedCancellationWithoutCleanupReceiptReportsRecoverableWorkspace() async throws {
        let id = UUID(), lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        let worker = try client("stall", id: id, idle: 3, grace: 0.1)
        let work = Task { try await worker.benchmark(drive: drive, volume: volume, config: benchmark, id: id, lease: lease) }
        let pid = try await waitForReady(); work.cancel()
        do { _ = try await work.value; XCTFail("unconfirmed cleanup must remain visible") }
        catch let error as MeasurementWorkerError {
            XCTAssertTrue(error.localizedDescription.contains(WorkspaceJournal.prefix + id.uuidString))
        }
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        let found = try DiskWorkspaceRecovery.scanFixture(at: root).leftovers
        XCTAssertEqual(found.count, 1); XCTAssertEqual(found[0].status, .recoverable)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found[0])
    }
    private func request() throws -> MeasurementRequest {
        let request = MeasurementRequest(drive: drive, volume: volume, lockToken: UUID(), operation: .benchmark(benchmark)); try request.validate(); return request
    }
    private func frame(_ request: MeasurementRequest, _ sequence: Int, _ payload: MeasurementPayload) throws -> Data {
        try JSONEncoder().encode(MeasurementFrame(id: request.id, sequence: sequence, payload: payload)) + Data([10])
    }
    func testJournalReceiptIsRequiredAndMustBindTheActualDurableResult() throws {
        let job = try MeasurementJournal(rootURL: root.appendingPathComponent("journal")).prepare(.init(drive: drive, driveKey: "fixture", volume: volume, operation: .benchmark(benchmark)))
        let request = MeasurementRequest(id: job.intent.id, drive: drive, volume: volume, lockToken: UUID(), operation: .benchmark(benchmark), job: job.ticket)
        func result(_ rate: Double) -> BenchmarkResult {
            .init(capturedAt: Date(timeIntervalSince1970: 1700000000), volumeBSDName: volume.bsdName, volumeName: volume.name, mountPoint: volume.mountPoint,
                fileSizeBytes: benchmark.fileSizeBytes, sequentialBlockBytes: benchmark.sequentialBlockBytes, randomBlockBytes: benchmark.randomBlockBytes,
                queueDepth: benchmark.queueDepth, sequentialWriteBytesPerSec: rate, sequentialReadBytesPerSec: 200, randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
        }
        let saved = result(100); try job.writeTerminal(.init(intent: job.intent, outcome: .benchmark(saved)))
        let hash = try job.record().recordSHA256
        func prepared() throws -> MeasurementStream {
            let stream = MeasurementStream(request: request, job: job, progress: { _ in })
            _ = try stream.consume(frame(request, 1, .prepared))
            for (sequence, phase) in [(2, BenchmarkPhase.sequentialWrite), (3, .sequentialRead)] {
                _ = try stream.consume(frame(request, sequence, .benchmarkProgress(.init(phase: phase, fractionCompleted: 1,
                    instantaneousBytesPerSecond: 100, averageBytesPerSecond: 100, processedBytes: benchmark.fileSizeBytes))))
            }
            _ = try stream.consume(frame(request, 4, .cleaning(0))); return stream
        }
        let missing = try prepared(); XCTAssertThrowsError(try missing.consume(frame(request, 5, .benchmarkResult(saved))))
        let wrongHash = try prepared(); _ = try wrongHash.consume(frame(request, 5, .journalReceipt(String(repeating: "0", count: 64))))
        _ = try wrongHash.consume(frame(request, 6, .benchmarkResult(saved))); XCTAssertThrowsError(try wrongHash.finish())
        let changed = try prepared(); _ = try changed.consume(frame(request, 5, .journalReceipt(hash)))
        _ = try changed.consume(frame(request, 6, .benchmarkResult(result(101)))); XCTAssertThrowsError(try changed.finish())
        let valid = try prepared(); _ = try valid.consume(frame(request, 5, .journalReceipt(hash))); _ = try valid.consume(frame(request, 6, .benchmarkResult(saved)))
        guard case .benchmarkResult(let received) = try valid.finish() else { return XCTFail("Missing result") }
        XCTAssertEqual(received.sequentialWriteBytesPerSec, 100); XCTAssertEqual(try job.cachedRecord()?.recordSHA256, hash)
    }
    func testOldMeasurementProtocolOrMissingParentCannotAuthorizeExecution() throws {
        let current = try request()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        object["version"] = 1
        let old = try JSONDecoder().decode(MeasurementRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try old.validate())
        object["version"] = current.version
        var volume = try XCTUnwrap(object["volume"] as? [String: Any]); volume.removeValue(forKey: "writeDirectoryIdentity"); object["volume"] = volume
        let unbound = try JSONDecoder().decode(MeasurementRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try unbound.validate())
        var prepared = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(MeasurementFrame(id: current.id, sequence: 1, payload: .prepared))) as? [String: Any])
        prepared["version"] = 1
        XCTAssertThrowsError(try MeasurementStream(request: current, progress: { _ in }).consume(JSONSerialization.data(withJSONObject: prepared) + Data([10])))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["outside.txt"])
    }
    func testFramingUUIDSequenceBudgetsAndUnfinishedResultAreRejected() throws {
        let r = try request(), stream = MeasurementStream(request: r, progress: { _ in })
        let prepared = try frame(r, 1, .prepared)
        XCTAssertFalse(try stream.consume(prepared.prefix(2))); XCTAssertTrue(try stream.consume(prepared.dropFirst(2)))
        XCTAssertThrowsError(try stream.consume(frame(r, 1, .prepared)))
        let wrong = MeasurementRequest(drive: drive, volume: volume, lockToken: UUID(), operation: .benchmark(benchmark))
        XCTAssertThrowsError(try MeasurementStream(request: r, progress: { _ in }).consume(frame(wrong, 1, .prepared)))
        XCTAssertThrowsError(try MeasurementStream(request: r, progress: { _ in }).consume(Data(repeating: 65, count: MeasurementStream.frameLimit + 1)))
        XCTAssertThrowsError(try MeasurementStream(request: r, progress: { _ in }).finish())
        let terminal = MeasurementStream(request: r, progress: { _ in })
        _ = try terminal.consume(frame(r, 1, .prepared)); _ = try terminal.consume(frame(r, 2, .failure(cancelled: false, message: "fixture")))
        XCTAssertThrowsError(try terminal.consume(Data([10])))
        XCTAssertThrowsError(try terminal.finish()) { error in
            guard case MeasurementWorkerError.protocolViolation = error else { return XCTFail("invalid suffix must poison an earlier terminal frame") }
        }
    }
    func testNoIOProgressDoesNotExtendIdleAndPhaseRegressionIsRejected() throws {
        let r = try request(), stream = MeasurementStream(request: r, progress: { _ in })
        XCTAssertTrue(try stream.consume(frame(r, 1, .prepared)))
        let p = BenchmarkProgress(phase: .sequentialWrite, fractionCompleted: 0, instantaneousBytesPerSecond: 0, averageBytesPerSecond: 0)
        XCTAssertTrue(try stream.consume(frame(r, 2, .benchmarkProgress(p))))
        XCTAssertFalse(try stream.consume(frame(r, 3, .benchmarkProgress(p))))
        let fakeComplete = BenchmarkProgress(phase: .sequentialWrite, fractionCompleted: 1, instantaneousBytesPerSecond: 1, averageBytesPerSecond: 1, processedBytes: 0)
        XCTAssertThrowsError(try stream.consume(frame(r, 4, .benchmarkProgress(fakeComplete))))
        let other = MeasurementStream(request: r, progress: { _ in }); _ = try other.consume(frame(r, 1, .prepared))
        let skipped = BenchmarkProgress(phase: .sequentialRead, fractionCompleted: 0, instantaneousBytesPerSecond: 0, averageBytesPerSecond: 0)
        XCTAssertThrowsError(try other.consume(frame(r, 2, .benchmarkProgress(skipped))))
    }
    func testCapacityVerdictCannotClaimPassForPartialOrCorruptData() throws {
        let r = MeasurementRequest(drive: drive, volume: volume, lockToken: UUID(), operation: .capacity(capacity))
        let stream = MeasurementStream(request: r, progress: { _ in }); _ = try stream.consume(frame(r, 1, .prepared)); _ = try stream.consume(frame(r, 2, .cleaning(0)))
        let falsePass = CapacityVerifyResult(capturedAt: Date(), volumeName: volume.name, mountPoint: volume.mountPoint, bytesRequested: 16384, bytesWritten: 4096,
            bytesVerifiedOK: 4096, firstCorruptionOffset: nil, corruptedBlocks: 0, writeBytesPerSec: 1, readBytesPerSec: 1, verdict: .passedTestedRange, interruption: nil)
        XCTAssertThrowsError(try stream.consume(frame(r, 3, .capacityResult(falsePass))))
    }
    func testResultCannotBeAcceptedWithoutCleanupOrWithWrongVolume() throws {
        let r = MeasurementRequest(drive: drive, volume: volume, lockToken: UUID(), operation: .capacity(capacity))
        let result = CapacityVerifyResult(capturedAt: Date(), volumeName: volume.name, mountPoint: "/different", bytesRequested: 16384, bytesWritten: 16384,
            bytesVerifiedOK: 16384, firstCorruptionOffset: nil, corruptedBlocks: 0, writeBytesPerSec: 1, readBytesPerSec: 1, verdict: .passedTestedRange, interruption: nil)
        let stream = MeasurementStream(request: r, progress: { _ in }); _ = try stream.consume(frame(r, 1, .prepared))
        XCTAssertThrowsError(try stream.consume(frame(r, 2, .capacityResult(result))))
        let cleaned = MeasurementStream(request: r, progress: { _ in })
        _ = try cleaned.consume(frame(r, 1, .prepared)); _ = try cleaned.consume(frame(r, 2, .cleaning(0)))
        XCTAssertThrowsError(try cleaned.consume(frame(r, 3, .capacityResult(result))))
        let valid = CapacityVerifyResult(capturedAt: Date(), volumeName: volume.name, mountPoint: volume.mountPoint, bytesRequested: 16384,
            bytesWritten: 16384, bytesVerifiedOK: 16384, firstCorruptionOffset: nil, corruptedBlocks: 0,
            writeBytesPerSec: 1, readBytesPerSec: 1, verdict: .passedTestedRange, interruption: nil)
        let uncleaned = MeasurementStream(request: r, progress: { _ in }); _ = try uncleaned.consume(frame(r, 1, .prepared))
        XCTAssertThrowsError(try uncleaned.consume(frame(r, 2, .capacityResult(valid))))
    }
    func testResultCannotExceedOwnershipFileBudget() throws {
        var config = capacity; config.maxBytes = nil
        let r = MeasurementRequest(drive: drive, volume: volume, lockToken: UUID(), operation: .capacity(config))
        let bytes = UInt64(DiskWorkspaceRecovery.maximumFiles + 1) * config.fileSizeBytes
        let result = CapacityVerifyResult(capturedAt: Date(), volumeName: volume.name, mountPoint: volume.mountPoint,
            bytesRequested: bytes, bytesWritten: bytes, bytesVerifiedOK: bytes, firstCorruptionOffset: nil, corruptedBlocks: 0,
            writeBytesPerSec: 1, readBytesPerSec: 1, verdict: .passedTestedRange, interruption: nil)
        let stream = MeasurementStream(request: r, progress: { _ in })
        _ = try stream.consume(frame(r, 1, .prepared)); _ = try stream.consume(frame(r, 2, .cleaning(0)))
        XCTAssertThrowsError(try stream.consume(frame(r, 3, .capacityResult(result))))
    }
    func testActualProductionWorkerRejectsArbitraryDirectoryBeforeDataWrites() async throws {
        let worker = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mdrivehealth-worker")
        let client = MeasurementWorkerClient(executable: worker.path, timeout: 5, journalRootURL: root.appendingPathComponent("journal"))
        let lease = try DriveCommandLock.acquire(registryEntryID: driveID); defer { lease.release() }
        do { _ = try await client.benchmark(drive: drive, volume: volume, config: benchmark, lease: lease); XCTFail("fixture directory cannot be selected by production") }
        catch { XCTAssertTrue(error.localizedDescription.contains("attachment changed"), "\(error)") }
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
    func testActualProductionWorkerRequiresDelegationForAttachedDrive() async throws {
        let worker = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mdrivehealth-worker")
        guard case .drives(let drives) = try await HardwareWorkerClient(executable: worker.path).perform(.enumerate), let attached = drives.first(where: { !$0.isVirtual }) else { throw XCTSkip("No physical drive") }
        let job = try MeasurementJournal(rootURL: root.appendingPathComponent("journal")).prepare(.init(drive: attached,
            driveKey: DriveIdentity.resolve(for: attached).key, volume: volume, operation: .benchmark(benchmark)))
        let r = MeasurementRequest(id: job.intent.id, drive: attached, volume: volume, lockToken: UUID(), operation: .benchmark(benchmark), job: job.ticket)
        var command = ProcessCommand(worker.path, ["--measurement-worker"], timeout: 5, scope: "unbound-measurement-\(UUID())")
        command.input = try JSONEncoder().encode(r)
        command.inheritedFileDescriptors[5] = try job.delegatedFD()
        let result = try await BoundedProcess.run(command)
        let stream = MeasurementStream(request: r, job: job, progress: { _ in }); _ = try stream.consume(result.requireSuccess())
        XCTAssertThrowsError(try stream.finish()) { XCTAssertTrue($0.localizedDescription.contains("Unsafe device-lock"), "\($0)") }
        XCTAssertTrue(try DiskWorkspaceRecovery.scanFixture(at: root).leftovers.isEmpty)
    }
}
