/* Protocol and real-process isolation tests. MDriveHealth, GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

final class HardwareWorkerTests: XCTestCase {
    private var drive: DriveInfo { .init(registryEntryID: UInt64.max, bsdName: "disk999999", model: "Fixture", serialNumber: "fixture", firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata) }
    private var worker: URL { Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mdrivehealth-worker") }
    private var client: HardwareWorkerClient { .init(executable: worker.path) }
    private func acquireHostDrive(_ id: UInt64) async throws -> DriveCommandLock.Lease {
        for _ in 0..<300 {
            do { return try DriveCommandLock.acquire(registryEntryID: id) }
            catch DriveCommandLockError.busy { try await Task.sleep(for: .milliseconds(20)) }
        }
        throw DriveCommandLockError.busy
    }
    private func data(_ reply: HardwareReply) throws -> Data { try JSONEncoder().encode(reply) }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-lock-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); return url
    }
    func testRequestRoundTripAndOnlyMatchingReplyAccepted() throws {
        let request = HardwareRequest(operation: .inspect(drive, avoidWakingIdle: true))
        let decoded = try JSONDecoder().decode(HardwareRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.id, request.id); XCTAssertEqual(decoded.operation.drive, drive)
        let reply = HardwareReply(id: request.id, value: .inspection(.init(reading: nil, skippedAsleep: true, volumes: [])))
        guard case .inspection(let value) = try client.decode(data(reply), for: request) else { return XCTFail("wrong value") }
        XCTAssertTrue(value.skippedAsleep)
        XCTAssertThrowsError(try client.decode(data(.init(id: UUID(), value: reply.value)), for: request))
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id, value: .acknowledged)), for: request))
    }
    func testVersionMalformedBytesOversizedReplyAndEmptyEnvelopeRejected() throws {
        let request = HardwareRequest(operation: .enumerate)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data(.init(id: request.id, value: .drives([])))) as? [String: Any])
        for oldVersion in [1, 2] {
            object["version"] = oldVersion
            XCTAssertThrowsError(try client.decode(JSONSerialization.data(withJSONObject: object), for: request))
        }
        XCTAssertThrowsError(try client.decode(Data("invalid".utf8), for: request))
        XCTAssertThrowsError(try client.decode(Data(repeating: 0, count: DriveHardwareWorker.replyLimit + 1), for: request))
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id)), for: request))
    }
    func testRemoteErrorDoesNotAcceptValueAndDiagnosticIsBounded() throws {
        let request = HardwareRequest(operation: .enumerate)
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id, failure: "fixture unavailable")), for: request)) { XCTAssertTrue($0.localizedDescription.contains("unavailable")) }
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id, value: .drives([]), failure: "bad")), for: request))
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id, failure: String(repeating: "x", count: 4097))), for: request))
    }
    func testFleetAndLogBudgetsRejectDuplicateOrUnboundedRecords() throws {
        let request = HardwareRequest(operation: .enumerate)
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id, value: .drives([drive, drive]))), for: request))
        XCTAssertThrowsError(try client.decode(data(.init(id: request.id, value: .drives(Array(repeating: drive, count: 513)))), for: request))
        let log = HardwareRequest(operation: .selfTestLog(drive))
        let entry = ATASelfTestLogEntry(index: 1, testType: 1, statusByte: 0, powerOnHours: 1, failingLBA: nil)
        XCTAssertThrowsError(try client.decode(data(.init(id: log.id, value: .selfTestLog(Array(repeating: entry, count: 22)))), for: log))
    }
    func testWorkerCommandUsesBoundedStdinAndOneScopePerAttachment() throws {
        let probe = try client.command(.init(operation: .inspect(drive, avoidWakingIdle: false)))
        let log = try client.command(.init(operation: .selfTestLog(drive)))
        XCTAssertEqual(probe.scope, log.scope); XCTAssertLessThan(probe.input.count, DriveHardwareWorker.requestLimit)
        XCTAssertEqual(probe.stdoutLimit, DriveHardwareWorker.replyLimit)
        XCTAssertNotEqual(try client.command(.init(operation: .memory)).scope, try client.command(.init(operation: .enumerate)).scope)
    }
    func testActualWorkerRejectsMalformedRequestAndChangedAttachment() async throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: worker.path), "SwiftPM worker must be built alongside tests")
        var request = ProcessCommand(worker.path, timeout: 5, scope: "malformed-worker-\(UUID())"); request.input = Data("bad request".utf8)
        let result = try await BoundedProcess.run(request)
        XCTAssertEqual(result.termination, .exited(2)); XCTAssertTrue(result.stdout.isEmpty)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(HardwareRequest(operation: .memory))) as? [String: Any])
        old["version"] = 2; request.input = try JSONSerialization.data(withJSONObject: old)
        let rejected = try await BoundedProcess.run(request)
        XCTAssertEqual(rejected.termination, .exited(2)); XCTAssertTrue(rejected.stdout.isEmpty)
        do { _ = try await client.perform(.validate(drive)); XCTFail("a non-existent attachment cannot be used") }
        catch { XCTAssertTrue(error.localizedDescription.contains("attachment changed")) }
    }
    func testTimedOutRealChildDoesNotHoldAnIndependentWorkerRequest() async throws {
        let blocked = HardwareWorkerClient(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.15)
        let started = Date(), stuck = Task { try await blocked.perform(.enumerate) }
        guard case .memory = try await client.perform(.memory) else { return XCTFail("healthy worker must still reply") }
        do { _ = try await stuck.value; XCTFail("blocked child must time out") }
        catch let error as CommandError {
            XCTAssertEqual(error.reason, .timedOut)
            if let pending = error.pendingChild { await pending.waitForExit() }
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            XCTAssertEqual(kill(try XCTUnwrap(error.processID), 0), -1); XCTAssertEqual(errno, ESRCH)
        }
    }
    func testActualWorkerCannotProbeWhileAnotherProcessOwnsDriveLock() async throws {
        guard case .drives(let drives) = try await client.perform(.enumerate), let real = drives.first else { throw XCTSkip("No block-storage device on this host") }
        let lease = try await acquireHostDrive(real.id); defer { lease.release() }
        do { _ = try await client.perform(.inspect(real, avoidWakingIdle: true)); XCTFail("worker process must honor parent's command lock") }
        catch { XCTAssertTrue(error.localizedDescription.contains("owns this device")) }
    }
    func testSameDeviceLocksExcludeAndDifferentDeviceLocksCoexist() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DriveCommandLock.acquire(registryEntryID: 1, directory: directory)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 1, directory: directory))
        let other = try DriveCommandLock.acquire(registryEntryID: 2, directory: directory)
        other.release(); first.release(); first.release()
        let again = try DriveCommandLock.acquire(registryEntryID: 1, directory: directory); again.release()
    }
    func testDelegatedDescriptorRetainsDeviceLockAfterParentClosesItsReference() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready"), identifier = UInt64(getpid()) << 32 | 1
        let lease = try DriveCommandLock.acquire(registryEntryID: identifier)
        var command = ProcessCommand("/bin/sh", ["-c", "trap '' TERM; printf ready > \"$1\"; while :; do :; done", "fixture", ready.path], timeout: 10, scope: "delegated-child-\(UUID())")
        command.inheritedFileDescriptors[3] = try lease.delegatedFD(); command.terminateGrace = 0.05
        let task = Task { try await BoundedProcess.run(command) }
        defer { task.cancel(); lease.release() }
        for _ in 0..<800 where !FileManager.default.fileExists(atPath: ready.path) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        lease.release()
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: identifier))
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") }
        catch let error as CommandError { if let pending = error.pendingChild { await pending.waitForExit() } }
        let next = try DriveCommandLock.acquire(registryEntryID: identifier); next.release()
    }
    func testActualWorkerValidatesDelegatedLeaseBeforeMeasurement() async throws {
        guard case .drives(let drives) = try await client.perform(.enumerate), let real = drives.first else { throw XCTSkip("No block-storage device on this host") }
        let lease = try await acquireHostDrive(real.id); defer { lease.release() }
        _ = try await client.measurementStatus(real, lease: lease)
        var forged = try client.command(.init(operation: .measurementStatus(real, lockToken: UUID())))
        forged.inheritedFileDescriptors[3] = try lease.delegatedFD()
        let output = try await BoundedProcess.run(forged)
        let reply = try JSONDecoder().decode(HardwareReply.self, from: output.requireSuccess())
        XCTAssertNil(reply.value); XCTAssertNotNil(reply.failure)
        lease.release()
        // The API must retain a temporary lease argument until child launch
        // and exit, including in an optimized Release build.
        _ = try await client.measurementStatus(real, lease: try await acquireHostDrive(real.id))
    }
    func testLockRefusesSymlinksHardlinksAndPublicDirectories() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("user-data")
        try Data("keep".utf8).write(to: target); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let lock = directory.appendingPathComponent("drive-1.lock")
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 1, directory: directory))
        try FileManager.default.removeItem(at: lock); XCTAssertEqual(link(target.path, lock.path), 0)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 1, directory: directory))
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        try FileManager.default.removeItem(at: lock)
        try Data("unrelated file".utf8).write(to: lock)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 1, directory: directory))
        XCTAssertEqual(try Data(contentsOf: lock), Data("unrelated file".utf8))
        let prefixed = Data("MDriveHealth-device-lock-v1\nnot a lock record\nuser notes".utf8)
        try prefixed.write(to: lock)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 1, directory: directory))
        XCTAssertEqual(try Data(contentsOf: lock), prefixed, "a matching prefix alone cannot authorize overwriting user bytes")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try DriveCommandLock.acquire(registryEntryID: 2, directory: directory))
    }
    func testThrowingBodyReleasesLockAndDoesNotLeakDescriptors() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        func descriptors() -> Set<Int32> { Set((0..<1024).compactMap { fcntl(Int32($0), F_GETFD) < 0 ? nil : Int32($0) }) }
        let before = descriptors()
        for _ in 0..<40 {
            XCTAssertThrowsError(try DriveCommandLock.withLock(registryEntryID: 1, directory: directory) { throw HardwareWorkerError.protocolViolation })
        }
        XCTAssertEqual(descriptors(), before)
        XCTAssertEqual(try DriveCommandLock.withLock(registryEntryID: 1, directory: directory) { 7 }, 7)
    }
}
