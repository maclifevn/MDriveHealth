/* Publish history changes only after persistence settles. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private final class HistoryOpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    func open(_ url: URL) throws -> HistoryStore {
        lock.lock(); didEnter = true; lock.unlock()
        guard semaphore.wait(timeout: .now() + 10) == .success else { throw HistoryError.unavailable }
        return try HistoryStore(databaseURL: url)
    }
    func release() { semaphore.signal() }
}

private struct HistoryPublicationScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}

final class HistoryPublicationTests: XCTestCase {
    @MainActor private var fixtures: [(DriveStore, URL, HistoryOpenGate?)] = []
    override func tearDown() async throws {
        try await closeFixtures()
        try await super.tearDown()
    }
    @MainActor private func closeFixtures() async throws {
        for (store, directory, gate) in fixtures {
            gate?.release(); store.beginShutdown()
            await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            try await store.history.shutdown()
            try FileManager.default.removeItem(at: directory)
        }
        fixtures.removeAll()
    }
    private var drive: DriveInfo {
        .init(registryEntryID: 821, bsdName: "disk821", model: "Publication fixture", serialNumber: "PUBLICATION-ONLY",
              firmwareRevision: "F", sizeBytes: 1_000_000, interconnect: "USB", location: "External",
              isSolidState: true, smartInterface: .ata)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("history-publication-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    @MainActor func testSMARTPublishesBeforeBlockedPersistenceButHistoryRevisionWaitsForCommit() async throws {
        let directory = try directory(), gate = HistoryOpenGate()
        let database = directory.appendingPathComponent("history.sqlite")
        let access = HistoryAccess(factory: { try gate.open(database) })
        let store = DriveStore(history: access, ioScanner: HistoryPublicationScanner(), hardware: FixtureHardware(drives: [drive]),
                               measurementRecovery: SystemMeasurementRecovery(rootURL: directory.appendingPathComponent("journal")))
        fixtures.append((store, directory, gate)); defer { gate.release() }
        let before = store.historyRevision
        let refresh = Task { await store.refresh() }
        let deadline = ContinuousClock().now + .seconds(5)
        while !gate.entered && ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.entered)
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotNil(store.lastRefresh)
        let snapshot = try XCTUnwrap(store.snapshots.first)
        XCTAssertNotNil(snapshot.reading)
        XCTAssertEqual(store.historyRevision, before)
        gate.release()
        await refresh.value
        await store.waitForBackgroundWork()
        XCTAssertFalse(store.isRefreshing)
        XCTAssertNotEqual(store.historyRevision, before)
        let key = snapshot.identity.key
        let rows = try await access.run("fixture.query") { try await $0.history(driveKey: key, since: Date(timeIntervalSince1970: 0)) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(try XCTUnwrap(rows.first).capturedAt.timeIntervalSince1970,
                       try XCTUnwrap(snapshot.reading).capturedAt.timeIntervalSince1970,
                       accuracy: 0.000001)
    }

    @MainActor func testFailedPersistenceAttemptNotifiesHistoryWithoutClaimingSavedData() async throws {
        let directory = try directory()
        let access = HistoryAccess(factory: { throw HistoryError.unavailable })
        let store = DriveStore(history: access, ioScanner: HistoryPublicationScanner(), hardware: FixtureHardware(drives: [drive]),
                               measurementRecovery: SystemMeasurementRecovery(rootURL: directory.appendingPathComponent("journal")))
        fixtures.append((store, directory, nil))
        let before = store.historyRevision
        await store.refresh(); await store.waitForBackgroundWork()
        XCTAssertNotEqual(store.historyRevision, before)
        XCTAssertEqual(access.state, .unavailable)
        XCTAssertTrue(access.isDegraded)
        XCTAssertNotNil(access.firstIssue)
        XCTAssertNotNil(store.snapshots.first?.reading)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.sqlite").path))
    }
}
