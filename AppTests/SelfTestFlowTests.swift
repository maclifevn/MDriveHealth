/* Real app flow, real disposable SQLite, recording hardware/notification boundaries. GPL-3.0-or-later. */
import XCTest
import SQLite3
@testable import MDriveHealthCore

private func selfTestSQL(_ url: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw HistoryError.unavailable }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw HistoryError.invalidData(String(cString: sqlite3_errmsg(db))) }
}
private final class JournalOpeningGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var started = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return started }
    func wait() { condition.lock(); started = true; while !released { condition.wait() }; condition.unlock() }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
}
private struct SelfTestEmptyScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}
private actor JournalHardware: DriveHardwareServing {
    enum Failure { case notIssued, uncertain, acceptedSave, log }
    let drive = DriveInfo(registryEntryID: 888888881, bsdName: "disk9999", model: "Fixture", serialNumber: "SN-JOURNAL",
                          firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
    let url: URL
    var failure: Failure?
    var head = 0, logStatus: UInt8 = 0, terminalStatus: UInt8 = 0, testType: UInt8 = 1
    var duplicate = false, sleeping = false
    private(set) var dispatched: [UUID] = [], issued = 0
    private(set) var phaseAtDispatch: SelfTestRunPhase?
    private(set) var avoidIdle: [Bool] = []
    init(url: URL) { self.url = url }
    func setFailure(_ failure: Failure?) { self.failure = failure }
    func setDuplicate() { duplicate = true }
    func setSleeping() { sleeping = true }
    func setProgress() { terminalStatus = 0xf5 }
    func finish(status: UInt8 = 0, type: UInt8 = 1) { head = head % 21 + 1; logStatus = status; terminalStatus = status; testType = type }
    func reading() -> ATASMARTReading {
        .init(capturedAt: Date(), identify: .init(model: drive.model, serialNumber: drive.serialNumber!, firmwareRevision: "F", rotationRate: 1),
              attributes: [], overallFailurePredicted: nil, selfTest: .init(rawByte: terminalStatus), driveFamily: nil, driveWarning: nil, selfTestSupported: true)
    }
    func observation() throws -> SelfTestObservation {
        let reading = reading()
        let entries: [ATASelfTestLogEntry] = head == 0 ? [] : [.init(index: 1, testType: testType, statusByte: logStatus, powerOnHours: 123,
                                                                   failingLBA: logStatus >> 4 == 7 ? 42 : nil, physicalSlot: head)]
        return .init(reading: reading, log: try .init(capturedAt: Date(), mostRecentSlot: head, entries: entries))
    }
    func enumerate() async throws -> [DriveInfo] {
        guard duplicate else { return [drive] }
        return [drive, .init(registryEntryID: drive.id + 1, bsdName: "disk9998", model: drive.model, serialNumber: drive.serialNumber,
            firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)]
    }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection {
        .init(reading: sleeping && avoidWakingIdle ? nil : .ata(reading()), skippedAsleep: sleeping && avoidWakingIdle, volumes: [])
    }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { try observation().log.entries }
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation {
        avoidIdle.append(avoidWakingIdle)
        if failure == .log { throw HardwareWorkerError.remote("fixture log unavailable") }
        if sleeping && avoidWakingIdle { throw HardwareWorkerError.deviceAsleep }
        return try observation()
    }
    func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt {
        let disk = try HistoryStore(databaseURL: url)
        phaseAtDispatch = try await disk.selfTestState(driveKey: command.driveKey)?.state.activeRun?.phase
        guard phaseAtDispatch == .commandPending else { throw SelfTestCommandError.notIssued("Intent was not durable") }
        dispatched.append(command.runID)
        if failure == .notIssued { throw SelfTestCommandError.notIssued("fixture precondition") }
        issued += 1
        if failure == .uncertain { throw SelfTestCommandError.uncertain("fixture lost ACK") }
        if failure == .acceptedSave {
            try selfTestSQL(url, "CREATE TRIGGER reject_accepted BEFORE UPDATE ON self_test_tracking WHEN instr(NEW.state,'\"phase\":\"accepted\"') > 0 BEGIN SELECT RAISE(FAIL,'fixture accepted save'); END")
        }
        return .init(runID: command.runID, acceptedAt: Date())
    }
}
@MainActor private final class JournalNotifications: NotificationDelivering {
    var status: NotificationAccess = .allowed, fail = false
    var registered: Set<String> = []
    var sent: [DriveAlert] = [], attempts: [DriveAlert] = []
    var failDeliveryCommitAt: URL?
    var permissionCalls = 0
    var holdSend = false, sendEntered = false
    var heldSend: CheckedContinuation<Void, Never>?
    func releaseSend() { heldSend?.resume(); heldSend = nil }
    func access() async -> NotificationAccess { status }
    func requestPermission() async throws -> Bool { permissionCalls += 1; status = .allowed; return true }
    func registeredRequestIDs() async -> Set<String> { registered }
    func send(_ alert: DriveAlert) async throws {
        attempts.append(alert)
        if holdSend { holdSend = false; sendEntered = true; await withCheckedContinuation { heldSend = $0 } }
        if fail { throw HardwareWorkerError.remote("fixture notification failed") }
        sent.append(alert); registered.insert(alert.id)
        if let url = failDeliveryCommitAt {
            try selfTestSQL(url, "CREATE TRIGGER reject_delivered BEFORE UPDATE ON self_test_events WHEN NEW.delivery_state='delivered' BEGIN SELECT RAISE(FAIL,'fixture delivered save'); END")
            failDeliveryCommitAt = nil
        }
    }
}
@MainActor private final class JournalHarness {
    static var pendingCleanup: [JournalHarness] = []
    let directory: URL, url: URL, hardware: JournalHardware, access: HistoryAccess, store: DriveStore
    let defaults: UserDefaults, suite: String
    private var stores: [DriveStore] = []
    private var monitors: [MonitoringController] = []
    init(unavailable: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("self-test-flow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        url = directory.appendingPathComponent("history.db")
        hardware = JournalHardware(url: url)
        let url = url
        access = HistoryAccess(factory: { if unavailable { throw HistoryError.unavailable }; return try HistoryStore(databaseURL: url) })
        store = DriveStore(history: access, ioScanner: SelfTestEmptyScanner(), hardware: hardware)
        suite = "self-test-notifications-\(UUID())"; defaults = UserDefaults(suiteName: suite)!
        stores = [store]; Self.pendingCleanup.append(self)
    }
    func close() {
        for monitor in monitors { monitor.beginShutdown() }
        for store in stores { store.beginShutdown() }
    }
    func manage(_ store: DriveStore) { stores.append(store) }
    static func drainFixtures() async throws {
        let fixtures = pendingCleanup; pendingCleanup.removeAll()
        for fixture in fixtures {
            fixture.close()
            for monitor in fixture.monitors { await monitor.shutdown() }
            for store in fixture.stores {
                await store.operations.waitForIdle(); await store.waitForBackgroundWork()
                try await store.history.shutdown()
            }
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try FileManager.default.removeItem(at: fixture.directory)
        }
    }
    var drive: DriveInfo { store.snapshots[0].drive }
    var key: String { store.snapshots[0].identity.key }
    func start() async throws { await store.refresh(); try await store.startSelfTest(drive, extended: false) }
    func events() async throws -> [StoredSelfTestEvent] { try await access.run("test.events") { try await $0.selfTestEvents() } }
    func reopen() -> DriveStore {
        let url = url
        let reopened = DriveStore(history: HistoryAccess(factory: { try HistoryStore(databaseURL: url) }), ioScanner: SelfTestEmptyScanner(), hardware: hardware)
        stores.append(reopened); return reopened
    }
    func monitor(_ delivery: JournalNotifications, enabled: Bool = true, store: DriveStore? = nil) -> MonitoringController {
        defaults.set(enabled, forKey: SettingsKeys.monitoringEnabled)
        let monitor = MonitoringController(store: store ?? self.store, defaults: defaults, delivery: delivery, observePreferences: false)
        monitors.append(monitor); return monitor
    }
}

final class SelfTestFlowTests: XCTestCase {
    override func tearDown() async throws { try await JournalHarness.drainFixtures(); try await super.tearDown() }
    @MainActor func testShutdownWaitsForInFlightSDKAndPersistsDeliveryBeforeClosingSQLite() async throws {
        let h = try JournalHarness(); defer { h.close() }
        try await h.start()
        let delivery = JournalNotifications(), monitor = h.monitor(delivery)
        await monitor.start(); delivery.holdSend = true
        await h.hardware.finish(); await h.store.refresh()
        let evaluate = Task { await monitor.evaluateAlerts() }
        for _ in 0..<1000 { if delivery.sendEntered { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(delivery.sendEntered)
        var closed = false
        let shutdown = Task {
            h.store.beginShutdown(); await monitor.shutdown()
            await h.store.operations.waitForIdle(); await h.store.waitForBackgroundWork()
            try await h.access.shutdown(); closed = true
        }
        try await Task.sleep(for: .milliseconds(20)); XCTAssertFalse(closed); XCTAssertEqual(h.access.state, .ready)
        delivery.releaseSend(); await evaluate.value; try await shutdown.value
        XCTAssertEqual(h.access.state, .closed)
        let check = try HistoryStore(databaseURL: h.url); defer { try? check.close() }
        let events = try await check.selfTestEvents()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.delivery, .delivered)
        XCTAssertEqual(delivery.sent.count, 1)
    }
    @MainActor func testFreshFirmwareProgressBlocksConflictsEvenWhenTrackingSaveFails() async throws {
        let h = try JournalHarness(); defer { h.close() }; await h.store.refresh()
        try selfTestSQL(h.url, "CREATE TRIGGER reject_observed BEFORE UPDATE ON self_test_tracking WHEN instr(NEW.state,'\"phase\":\"observed\"') > 0 BEGIN SELECT RAISE(FAIL,'fixture observed save'); END")
        await h.hardware.setProgress()
        do { _ = try await h.store.observeSelfTest(h.drive); XCTFail("journal fault") } catch {}
        XCTAssertNotNil(h.store.selfTests.issues[h.key])
        XCTAssertFalse(h.store.operations.canBegin(driveID: h.drive.id, kind: .eject))
        XCTAssertFalse(h.store.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
        XCTAssertTrue(h.store.operations.canBegin(driveID: h.drive.id, kind: .probe))
    }
    @MainActor func testIncompleteJournalRecoveryBlocksCommandsOnLaterDriveAndRefreshReentry() async throws {
        let h = try JournalHarness(); defer { h.close() }
        let first = DriveInfo(registryEntryID: 888888883, bsdName: "disk9997", model: "Fixture", serialNumber: "RECOVERY-A",
            firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
        let second = DriveInfo(registryEntryID: 888888884, bsdName: "disk9996", model: "Fixture", serialNumber: "RECOVERY-B",
            firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
        let gate = JournalOpeningGate(), url = h.url, hardware = FixtureHardware(drives: [first, second])
        defer { gate.release() }
        let history = HistoryAccess(factory: { gate.wait(); return try HistoryStore(databaseURL: url) })
        let store = DriveStore(history: history, ioScanner: SelfTestEmptyScanner(), hardware: hardware)
        h.manage(store)
        let refresh = Task { await store.refresh() }
        for _ in 0..<1000 { if gate.entered && !store.isRefreshing { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(gate.entered); XCTAssertFalse(store.isRefreshing)
        XCTAssertTrue(store.operations.isResolvingFleet)
        XCTAssertFalse(store.operations.canBegin(driveID: second.id, kind: .selfTestStart))
        XCTAssertFalse(store.operations.canBegin(driveID: second.id, kind: .eject))
        XCTAssertFalse(store.operations.canBegin(driveID: second.id, kind: .benchmark))
        do { try await store.startSelfTest(second, extended: false); XCTFail("recovery must complete first") }
        catch { XCTAssertTrue(error is DriveOperationError) }
        let before = await hardware.inspections
        await store.refresh()
        let after = await hardware.inspections; XCTAssertEqual(before, after, "refresh cannot reenter while recovering")
        gate.release(); await refresh.value
        XCTAssertFalse(store.operations.isResolvingFleet)
        XCTAssertTrue(store.operations.canBegin(driveID: second.id, kind: .selfTestStart))
    }
    @MainActor func testSDKAcceptanceThenDBFailureReconcilesWithoutDuplicateSubmission() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start(); await h.hardware.finish(); await h.store.pollSelfTests()
        let delivery = JournalNotifications(); delivery.failDeliveryCommitAt = h.url
        let monitor = h.monitor(delivery); await monitor.start(); await monitor.evaluateAlerts()
        let first = try await h.events(); XCTAssertEqual(first.first?.delivery, .sending)
        XCTAssertEqual(delivery.sent.count, 1); XCTAssertNotNil(monitor.deliveryError)
        try selfTestSQL(h.url, "DROP TRIGGER reject_delivered")
        await monitor.evaluateAlerts(); monitor.stop()
        let after = try await h.events(); XCTAssertEqual(after.first?.delivery, .delivered)
        XCTAssertEqual(delivery.sent.count, 1)
    }
    @MainActor func testRestartWithBlockedLogStillRestoresOwnershipAndRunIdentity() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let id = try XCTUnwrap(h.store.selfTests.states[h.key]?.state.activeRun?.id)
        await h.hardware.setFailure(.log)
        let reopened = h.reopen(); await reopened.refresh()
        XCTAssertEqual(reopened.selfTests.states[h.key]?.state.activeRun?.id, id)
        XCTAssertNotNil(reopened.selfTests.issues[h.key])
        XCTAssertFalse(reopened.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
        let events = try await h.events(); XCTAssertTrue(events.isEmpty)
    }
    @MainActor func testRestartWithSleepingDriveRestoresRunWithoutReadingLog() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let id = try XCTUnwrap(h.store.selfTests.states[h.key]?.state.activeRun?.id)
        let calls = await h.hardware.avoidIdle.count
        await h.hardware.setSleeping()
        let reopened = h.reopen(); await reopened.refresh(wakingSleepingDrives: false)
        XCTAssertEqual(reopened.selfTests.states[h.key]?.state.activeRun?.id, id)
        let after = await h.hardware.avoidIdle.count; XCTAssertEqual(after, calls)
    }
    @MainActor func testExplicitClosureRecordsIndeterminateAndReleasesOwnership() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let id = try XCTUnwrap(h.store.selfTests.states[h.key]?.state.activeRun?.id)
        _ = try await h.store.observeSelfTest(h.drive, closeWithoutResult: true)
        let events = try await h.events()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].event.id, id); XCTAssertEqual(events[0].event.outcome, .indeterminate)
        let reopened = h.reopen(); await reopened.refresh()
        XCTAssertEqual(reopened.selfTests.latestCompletions[h.key]?.outcome, .indeterminate)
        XCTAssertTrue(h.store.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
        let issued = await h.hardware.issued; XCTAssertEqual(issued, 1)
    }
    @MainActor func testPreparedIntentAtRestartIsClearedWithoutIssuingCommand() async throws {
        let h = try JournalHarness(); defer { h.close() }; await h.store.refresh()
        let observation = try await h.hardware.observation()
        _ = try await h.store.selfTests.prepare(key: h.key, model: h.drive.model, kind: .short, baseline: observation.log)
        let reopened = h.reopen(); await reopened.refresh()
        XCTAssertNil(reopened.selfTests.states[h.key]?.state.activeRun)
        let issued = await h.hardware.issued; XCTAssertEqual(issued, 0)
        let events = try await h.events(); XCTAssertTrue(events.isEmpty)
    }
    @MainActor func testOutboxCrossProcessLockPreventsClaimReconciliationDuringAnotherSender() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start(); await h.hardware.finish(); await h.store.pollSelfTests()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-notification-locks-v1")
        let lock = try await DriveCommandLock.acquireAsync(registryEntryID: 1, directory: directory)
        let delivery = JournalNotifications(), monitor = h.monitor(delivery)
        await monitor.start(); await monitor.evaluateAlerts()
        XCTAssertTrue(delivery.sent.isEmpty)
        let first = try await h.events(); XCTAssertEqual(first.first?.delivery, .pending)
        lock.release(); await monitor.evaluateAlerts(); monitor.stop()
        XCTAssertEqual(delivery.sent.count, 1)
    }
    @MainActor func testDismissUncertainNotificationRetainsResultWithoutResending() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start(); await h.hardware.finish(); await h.store.pollSelfTests()
        let events = try await h.events(), event = try XCTUnwrap(events.first?.event)
        _ = try await h.access.run("test.claim") { try await $0.transitionSelfTestEvent(id: event.id, from: .pending, to: .sending) }
        let delivery = JournalNotifications(), monitor = h.monitor(delivery)
        await monitor.start(); await monitor.evaluateAlerts(); await monitor.dismissUncertainSelfTestNotifications(); monitor.stop()
        let after = try await h.events()
        XCTAssertEqual(after.first?.delivery, .suppressed); XCTAssertEqual(after.first?.event, event)
        XCTAssertTrue(delivery.sent.isEmpty); XCTAssertEqual(monitor.uncertainSelfTestNotifications, 0)
    }
    @MainActor func testIntentDurableBeforeCommandAndAcceptedRestoresAcrossAppRestart() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let selfTestValue1 = await h.hardware.phaseAtDispatch
        XCTAssertEqual(selfTestValue1, .commandPending)
        let run = try XCTUnwrap(h.store.selfTests.states[h.key]?.state.activeRun)
        XCTAssertEqual(run.phase, .accepted); XCTAssertNotNil(run.acceptedAt)
        let reopened = h.reopen(); await reopened.refresh()
        XCTAssertEqual(reopened.selfTests.states[h.key]?.state.activeRun?.id, run.id)
        XCTAssertFalse(reopened.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
        let selfTestValue2 = await h.hardware.issued
        XCTAssertEqual(selfTestValue2, 1)
    }
    @MainActor func testConsecutiveIdenticalPassAndFailCompletedBetweenPollsEachRetainOneEvent() async throws {
        for status in [UInt8(0), 0x70] {
            let h = try JournalHarness(); defer { h.close() }; try await h.start()
            for cycle in 1...2 {
                await h.hardware.finish(status: status); await h.store.pollSelfTests(activeOnly: true)
                if cycle == 1 { try await h.store.startSelfTest(h.drive, extended: false) }
            }
            let events = try await h.events()
            XCTAssertEqual(events.count, 2); XCTAssertNotEqual(events[0].event.id, events[1].event.id)
            XCTAssertEqual(events.map { $0.event.outcome }, Array(repeating: status == 0 ? .passed : .failed, count: 2))
            let reopened = h.reopen(); await reopened.refresh()
            let selfTestValue3 = try await h.events().count
            XCTAssertEqual(selfTestValue3, 2)
            XCTAssertNil(reopened.selfTests.states[h.key]?.state.activeRun)
        }
    }
    @MainActor func testAbortedRunPersistsSingleAbortedEvent() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        await h.hardware.finish(status: 0x20); await h.store.pollSelfTests(); await h.store.pollSelfTests()
        let events = try await h.events(); XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].event.outcome, .aborted)
        XCTAssertTrue(h.store.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
    }
    @MainActor func testUnavailableHistoryNeverIssuesCommandOrRetainsOperationLease() async throws {
        let h = try JournalHarness(unavailable: true); defer { h.close() }; await h.store.refresh()
        do { try await h.store.startSelfTest(h.drive, extended: false); XCTFail("must require journal") } catch {}
        let selfTestValue4 = await h.hardware.issued
        XCTAssertEqual(selfTestValue4, 0); XCTAssertTrue(h.store.operations.leases.isEmpty)
        XCTAssertFalse(h.store.operations.trackedSelfTests.contains(h.drive.id))
    }
    @MainActor func testTypedNotIssuedClearsIntentAndDoesNotBlockNextOperation() async throws {
        let h = try JournalHarness(); defer { h.close() }; await h.store.refresh(); await h.hardware.setFailure(.notIssued)
        do { try await h.store.startSelfTest(h.drive, extended: false); XCTFail("fixture failure") } catch {}
        let selfTestValue5 = await h.hardware.issued
        XCTAssertEqual(selfTestValue5, 0)
        XCTAssertNil(h.store.selfTests.states[h.key]?.state.activeRun)
        XCTAssertTrue(h.store.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
    }
    @MainActor func testLostACKRetainsIntentRestartResolvesWithoutResending() async throws {
        let h = try JournalHarness(); defer { h.close() }; await h.store.refresh(); await h.hardware.setFailure(.uncertain)
        do { try await h.store.startSelfTest(h.drive, extended: false); XCTFail("lost ACK") } catch {}
        XCTAssertEqual(h.store.selfTests.states[h.key]?.state.activeRun?.phase, .commandPending)
        await h.hardware.setFailure(nil); await h.hardware.finish()
        let reopened = h.reopen(); await reopened.refresh(); await reopened.pollSelfTests()
        let events = try await h.events(); XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].event.source, .commandUnconfirmed)
        let selfTestValue6 = await h.hardware.issued
        XCTAssertEqual(selfTestValue6, 1)
    }
    @MainActor func testACKSaveFailureRetainsPendingIntentAndNeverResendsCommand() async throws {
        let h = try JournalHarness(); defer { h.close() }; await h.store.refresh(); await h.hardware.setFailure(.acceptedSave)
        do { try await h.store.startSelfTest(h.drive, extended: false); XCTFail("ACK save must fail") } catch {}
        XCTAssertEqual(h.store.selfTests.states[h.key]?.state.activeRun?.phase, .commandPending)
        XCTAssertNotNil(h.store.selfTests.issues[h.key]); XCTAssertFalse(h.store.operations.canBegin(driveID: h.drive.id, kind: .benchmark))
        try selfTestSQL(h.url, "DROP TRIGGER reject_accepted")
        await h.hardware.setFailure(nil); await h.hardware.finish()
        let reopened = h.reopen(); await reopened.refresh()
        let selfTestValue7 = try await h.events().count
        let selfTestValue8 = await h.hardware.issued
        XCTAssertEqual(selfTestValue7, 1); XCTAssertEqual(selfTestValue8, 1)
    }
    @MainActor func testDuplicateIdentityCannotDispatchOrJoinDurableState() async throws {
        let h = try JournalHarness(); defer { h.close() }; await h.hardware.setDuplicate(); await h.store.refresh()
        XCTAssertFalse(h.store.snapshots[0].identity.isPersistent)
        do { try await h.store.startSelfTest(h.drive, extended: false); XCTFail("duplicate identity") } catch {}
        let selfTestValue9 = await h.hardware.issued
        XCTAssertEqual(selfTestValue9, 0); XCTAssertTrue(h.store.selfTests.states.isEmpty)
    }
    @MainActor func testLogFailureRetainsRunAndReportsErrorInsteadOfPass() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        await h.hardware.finish(); await h.hardware.setFailure(.log); await h.store.pollSelfTests()
        XCTAssertNotNil(h.store.selfTests.states[h.key]?.state.activeRun); XCTAssertNotNil(h.store.selfTests.issues[h.key])
        let selfTestValue10 = try await h.events().isEmpty
        XCTAssertTrue(selfTestValue10)
        await h.hardware.setFailure(nil); await h.store.pollSelfTests()
        let selfTestValue11 = try await h.events().count
        XCTAssertEqual(selfTestValue11, 1)
    }
    @MainActor func testFailedEventCommitDoesNotConsumeResultAndRetryKeepsRunID() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let id = try XCTUnwrap(h.store.selfTests.states[h.key]?.state.activeRun?.id)
        try selfTestSQL(h.url, "CREATE TRIGGER reject_result BEFORE INSERT ON self_test_events BEGIN SELECT RAISE(FAIL,'fixture result save'); END")
        await h.hardware.finish(); await h.store.pollSelfTests()
        let selfTestValue12 = try await h.events().isEmpty
        XCTAssertEqual(h.store.selfTests.states[h.key]?.state.activeRun?.id, id); XCTAssertTrue(selfTestValue12)
        try selfTestSQL(h.url, "DROP TRIGGER reject_result")
        await h.store.pollSelfTests(); let events = try await h.events()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events[0].event.id, id)
    }
    @MainActor func testSleepingSnapshotSkipsBackgroundLogRead() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let calls = await h.hardware.avoidIdle.count
        await h.hardware.setSleeping(); await h.store.refresh(wakingSleepingDrives: false); await h.store.pollSelfTests(activeOnly: true)
        let selfTestValue13 = await h.hardware.avoidIdle.count
        XCTAssertEqual(selfTestValue13, calls)
        XCTAssertNotNil(h.store.selfTests.states[h.key]?.state.activeRun)
    }
    @MainActor func testSDKFailureRetriesSameDurableIDAfterMonitorRestart() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start(); await h.hardware.finish(); await h.store.pollSelfTests()
        let delivery = JournalNotifications(); delivery.fail = true
        let first = h.monitor(delivery); await first.start(); await first.evaluateAlerts(); first.stop()
        let selfTestValue14 = try await h.events().first?.delivery
        XCTAssertEqual(selfTestValue14, .pending)
        delivery.fail = false
        let second = h.monitor(delivery); await second.start(); await second.evaluateAlerts(); second.stop()
        XCTAssertEqual(delivery.sent.count, 1); XCTAssertEqual(delivery.attempts.first?.id, delivery.sent.first?.id)
        let selfTestValue15 = try await h.events().first?.delivery
        XCTAssertEqual(selfTestValue15, .delivered)
    }
    @MainActor func testClaimedNotificationRestartsReconcileRegisteredIDWithoutResend() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start(); await h.hardware.finish(); await h.store.pollSelfTests()
        let selfTestValue16 = try await h.events().first?.event
        let event = try XCTUnwrap(selfTestValue16)
        _ = try await h.access.run("test.claim") { try await $0.transitionSelfTestEvent(id: event.id, from: .pending, to: .sending) }
        let delivery = JournalNotifications(); delivery.registered = ["self-test." + event.id.uuidString]
        let monitor = h.monitor(delivery); await monitor.start(); await monitor.evaluateAlerts(); monitor.stop()
        let selfTestValue17 = try await h.events().first?.delivery
        XCTAssertTrue(delivery.sent.isEmpty); XCTAssertEqual(selfTestValue17, .delivered)
    }
    @MainActor func testMissingSystemIDAfterClaimBecomesUncertainAndNeverAutomaticallyResends() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start(); await h.hardware.finish(); await h.store.pollSelfTests()
        let selfTestValue18 = try await h.events().first?.event
        let event = try XCTUnwrap(selfTestValue18)
        _ = try await h.access.run("test.claim") { try await $0.transitionSelfTestEvent(id: event.id, from: .pending, to: .sending) }
        let delivery = JournalNotifications(), monitor = h.monitor(delivery)
        await monitor.start(); await monitor.evaluateAlerts(); await monitor.retryNotifications(); monitor.stop()
        let selfTestValue19 = try await h.events().first?.delivery
        XCTAssertTrue(delivery.sent.isEmpty); XCTAssertEqual(selfTestValue19, .uncertain)
        XCTAssertEqual(monitor.uncertainSelfTestNotifications, 1); XCTAssertNotNil(monitor.deliveryError)
    }
    @MainActor func testMonitoringOffSuppressesCompletionAndReenableDoesNotSendBacklog() async throws {
        let h = try JournalHarness(); defer { h.close() }; try await h.start()
        let delivery = JournalNotifications(); delivery.status = .notDetermined
        let monitor = h.monitor(delivery, enabled: false); await monitor.start()
        await h.hardware.finish(); await h.store.pollSelfTests(); await monitor.evaluateAlerts()
        let selfTestValue20 = try await h.events().first?.delivery
        XCTAssertEqual(selfTestValue20, .suppressed); XCTAssertEqual(delivery.permissionCalls, 0)
        h.defaults.set(true, forKey: SettingsKeys.monitoringEnabled); monitor.preferencesChanged(refresh: false)
        await monitor.evaluateAlerts(); monitor.stop(); XCTAssertTrue(delivery.sent.isEmpty)
    }
}
