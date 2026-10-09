/* Connection ownership/drain tests with disposable SQLite. GPL-3.0-or-later. */
import XCTest
import SQLite3
@testable import MDriveHealthCore

private final class HistoryCloseGate: @unchecked Sendable {
    private let condition = NSCondition(); private var released = false, started = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func wait() { condition.lock(); started = true; while !released { condition.wait() }; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private actor HistoryRunGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
final class HistoryLifecycleTests: XCTestCase {
    private var directory: URL!
    private var url: URL { directory.appendingPathComponent("history.db") }
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-lifecycle-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private var result: BenchmarkResult { .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), volumeBSDName: "disk999s1", volumeName: "Fixture", mountPoint: "/fixture",
        fileSizeBytes: 4096, sequentialBlockBytes: 4096, randomBlockBytes: 4096, sequentialWriteBytesPerSec: 1,
        sequentialReadBytesPerSec: 2, randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil) }
    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("connection fixture never reached expected state"); throw HistoryError.unavailable
    }
    func testCloseIsIdempotentPersistsWritesAndRejectsQueriesOnClosedHandle() throws {
        let store = try HistoryStore(databaseURL: url), expected = result
        try store.record(benchmark: expected, driveKey: "fixture")
        try store.close(); try store.close()
        XCTAssertThrowsError(try store.latest(driveKey: "fixture")) { guard case HistoryError.unavailable = $0 else { return XCTFail("closed query must fail explicitly") } }
        XCTAssertThrowsError(try store.record(benchmark: expected, driveKey: "fixture"))
        let reopened = try HistoryStore(databaseURL: url); defer { try? reopened.close() }
        XCTAssertEqual(try reopened.latestBenchmark(driveKey: "fixture"), expected)
    }
    func testBusyCloseRetainsHandleUntilUnfinishedStatementIsFinalized() throws {
        let store = try HistoryStore(databaseURL: url); defer { try? store.close() }
        let statement = try store.serialQueue.sync { try store.prepare("SELECT 1") }
        XCTAssertThrowsError(try store.close()) { XCTAssertEqual(($0 as? HistoryError)?.sqliteCode, SQLITE_BUSY) }
        XCTAssertEqual(try store.legacyCounts().total, 0)
        _ = store.serialQueue.sync { sqlite3_finalize(statement) }
        try store.close(); XCTAssertThrowsError(try store.legacyCounts())
    }
    @MainActor func testCloseWaitsForSerializedWriteWithoutBlockingMainActor() async throws {
        let store = try HistoryStore(databaseURL: url), gate = HistoryCloseGate(), url = url
        defer { gate.release() }
        store.serialQueue.async {
            try! store.executeLocked("CREATE TABLE close_fixture(value INTEGER)")
            gate.wait(); try! store.executeLocked("INSERT INTO close_fixture VALUES(1)")
        }
        try await waitUntil { gate.entered }
        var closed = false
        let close = Task { try await store.close(); closed = true }
        try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(closed)
        gate.release(); try await close.value
        let reopened = try HistoryStore(databaseURL: url); defer { try? reopened.close() }
        XCTAssertEqual(try reopened.serialQueue.sync { try reopened.scalarInt("SELECT COUNT(*) FROM close_fixture") }, 1)
    }
    @MainActor func testShutdownDrainsAcceptedBodyAndRejectsNewWorkUntilExplicitResume() async throws {
        let url = url, access = HistoryAccess(factory: { try HistoryStore(databaseURL: url) }), gate = HistoryRunGate(), expected = result
        let accepted = Task { try await access.run("accepted") { store in await gate.wait(); try await store.record(benchmark: expected, driveKey: "fixture") } }
        for _ in 0..<1000 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(5)) }
        let entered = await gate.entered; XCTAssertTrue(entered)
        let shutdown = Task { try await access.shutdown() }
        try await waitUntil { access.state == .closing }
        do { _ = try await access.run("rejected") { try await $0.latest(driveKey: "fixture") }; XCTFail("shutdown must close admissions") } catch {}
        await gate.release(); try await accepted.value; try await shutdown.value
        XCTAssertEqual(access.state, .closed)
        do { try await access.connect(retry: true); XCTFail("retry cannot reopen a shutdown connection") } catch {}
        try access.resumeAfterShutdown()
        let stored = try await access.run("restored") { try await $0.latestBenchmark(driveKey: "fixture") }
        XCTAssertEqual(stored, expected); try await access.shutdown()
    }
    @MainActor func testShutdownWaitsForFactoryAndConcurrentCallersShareTheDrain() async throws {
        let gate = HistoryCloseGate(), url = url, access = HistoryAccess(factory: { gate.wait(); return try HistoryStore(databaseURL: url) })
        defer { gate.release() }
        let opening = Task { try await access.connect() }
        try await waitUntil { gate.entered }
        let first = Task { try await access.shutdown() }, second = Task { try await access.shutdown() }
        try await waitUntil { access.state == .closing }
        do { try access.resumeAfterShutdown(); XCTFail("cannot resume a live drain") } catch {}
        gate.release(); try await opening.value; try await first.value; try await second.value
        XCTAssertEqual(access.state, .closed)
        let check = try HistoryStore(databaseURL: url); try await check.close()
    }
    @MainActor func testFailedShutdownPreservesCloseIssueAndCanRetryAfterStatementRelease() async throws {
        let url = url, store = try HistoryStore(databaseURL: url), access = HistoryAccess(factory: { store })
        try await access.connect()
        let statement = try store.serialQueue.sync { try store.prepare("SELECT 1") }
        do { try await access.shutdown(); XCTFail("unfinished statement must not be hidden") }
        catch { XCTAssertEqual((error as? HistoryError)?.sqliteCode, SQLITE_BUSY) }
        XCTAssertEqual(access.state, .unavailable); XCTAssertNotNil(access.issues["close"])
        _ = store.serialQueue.sync { sqlite3_finalize(statement) }
        try await access.shutdown(); XCTAssertEqual(access.state, .closed); XCTAssertNil(access.issues["close"])
    }
}
