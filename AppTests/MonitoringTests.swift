/* Actual monitoring model with notification/clock/hardware fixtures.
 * MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private enum NotificationFixtureError: LocalizedError {
    case permission, send
    var errorDescription: String? { self == .permission ? "fixture permission failed" : "fixture delivery failed" }
}
@MainActor private final class FixtureNotifications: NotificationDelivering {
    var status: NotificationAccess = .allowed
    var failPermission = false, failSend = false, holdAccess = false
    var accessCalls = 0, permissionCalls = 0
    var sent: [DriveAlert] = [], attempted: [DriveAlert] = []
    var held: CheckedContinuation<Void, Never>?
    func access() async -> NotificationAccess {
        accessCalls += 1
        if holdAccess { holdAccess = false; await withCheckedContinuation { held = $0 } }
        return status
    }
    func release() { held?.resume(); held = nil }
    func requestPermission() async throws -> Bool {
        permissionCalls += 1
        if failPermission { throw NotificationFixtureError.permission }
        status = .allowed; return true
    }
    func send(_ alert: DriveAlert) async throws {
        attempted.append(alert)
        if failSend { throw NotificationFixtureError.send }
        sent.append(alert)
    }
    func count(_ category: String) -> Int { sent.filter { $0.category == category }.count }
}
@MainActor private final class FixtureClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval = 1) { date.addTimeInterval(seconds) }
}
private struct EmptyMonitoringScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}
private actor MonitoringHardware: DriveHardwareServing {
    enum Mode { case reading, sleeping, failed, unavailableHealth }
    let drive = DriveInfo(registryEntryID: 1, bsdName: "disk1", model: "Fixture", serialNumber: "S", firmwareRevision: "F",
                          sizeBytes: 1000, interconnect: "PCIe", location: "External", isSolidState: true, smartInterface: .nvme)
    var capturedAt: Date
    var temperature: Int? = 70
    var warning: NVMeCriticalWarning = []
    var mode: Mode = .reading
    var enumerations = 0
    init(capturedAt: Date) { self.capturedAt = capturedAt }
    func set(stamp: Date, temperature: Int? = 70, warning: NVMeCriticalWarning = [], mode: Mode = .reading) {
        capturedAt = stamp; self.temperature = temperature; self.warning = warning; self.mode = mode
    }
    func enumerate() async throws -> [DriveInfo] { enumerations += 1; return [drive] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection {
        if mode == .failed { throw HardwareWorkerError.remote("fixture unavailable") }
        if mode == .sleeping { return .init(reading: nil, skippedAsleep: true, volumes: []) }
        let reading = DriveReading.nvme(.init(controller: .init(model: "Fixture", serialNumber: "S", firmwareRevision: "F",
            ieeeOUI: "00-00-00", controllerID: 0, specVersion: nil, totalCapacityBytes: 1000, unallocatedCapacityBytes: 0,
            warningTempKelvin: 0, criticalTempKelvin: 0, namespaceCount: 1), smart: .init(capturedAt: capturedAt,
            criticalWarning: warning, temperatureKelvin: temperature.map { UInt16($0 + 273) } ?? 0,
            availableSpare: mode == .unavailableHealth ? 255 : 100, availableSpareThreshold: 10, percentageUsed: 1,
            dataUnitsRead: 1, dataUnitsWritten: 1, hostReadCommands: 1, hostWriteCommands: 1, controllerBusyTimeMinutes: 0,
            powerCycles: 1, powerOnHours: 1, unsafeShutdowns: 0, mediaErrors: 0, errorLogEntries: 0,
            warningTempTimeMinutes: 0, criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [])))
        return .init(reading: reading, skippedAsleep: false, volumes: [])
    }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
    func startSelfTest(_ drive: DriveInfo, extended: Bool) async throws {}
}

@MainActor private struct MonitorHarness {
    let suite = "monitor-fixture-\(UUID().uuidString)"
    let defaults: UserDefaults
    let clock: FixtureClock
    let notifications: FixtureNotifications
    let hardware: MonitoringHardware
    let store: DriveStore
    let monitor: MonitoringController
    init(enabled: Bool = true, observePreferences: Bool = false) {
        let defaults = UserDefaults(suiteName: suite)!, clock = FixtureClock(), notifications = FixtureNotifications()
        defaults.set(enabled, forKey: SettingsKeys.monitoringEnabled)
        let hardware = MonitoringHardware(capturedAt: clock.date)
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }),
                               ioScanner: EmptyMonitoringScanner(), hardware: hardware)
        self.defaults = defaults; self.clock = clock; self.notifications = notifications; self.hardware = hardware; self.store = store
        self.monitor = MonitoringController(store: store, defaults: defaults, delivery: notifications,
                                            now: { clock.date }, observePreferences: observePreferences)
    }
    func close() { monitor.stop(); defaults.removePersistentDomain(forName: suite) }
    func read(temperature: Int? = 70, warning: NVMeCriticalWarning = [], mode: MonitoringHardware.Mode = .reading, stamp: Date? = nil) async {
        clock.advance(); await hardware.set(stamp: stamp ?? clock.date, temperature: temperature, warning: warning, mode: mode)
        await store.refresh(wakingSleepingDrives: false); await monitor.evaluateAlerts()
    }
}

final class MonitoringTests: XCTestCase {
    @MainActor func testStopAndRestartRestoresTimerAndPreferenceObserver() async throws {
        let h = MonitorHarness(observePreferences: true); defer { h.close() }; await h.monitor.start()
        h.monitor.stop(); XCTAssertNil(h.monitor.scheduledIntervalMinutes)
        await h.monitor.start(); XCTAssertEqual(h.monitor.scheduledIntervalMinutes, 5)
        h.defaults.set(false, forKey: SettingsKeys.monitoringEnabled)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: h.defaults)
        for _ in 0..<1000 { if h.monitor.scheduledIntervalMinutes == nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(h.monitor.scheduledIntervalMinutes)
    }
    @MainActor func testPreferenceObserverReenablesPollingAndFreshAlertWithoutWindowReopen() async throws {
        let h = MonitorHarness(enabled: false, observePreferences: true); defer { h.close() }; await h.monitor.start()
        XCTAssertNil(h.monitor.scheduledIntervalMinutes)
        h.clock.advance(); await h.hardware.set(stamp: h.clock.date)
        h.defaults.set(true, forKey: SettingsKeys.monitoringEnabled)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: h.defaults)
        for _ in 0..<1000 { if h.notifications.count("temperature") == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(h.notifications.count("temperature"), 1); XCTAssertEqual(h.monitor.scheduledIntervalMinutes, 5)
        h.defaults.set(false, forKey: SettingsKeys.monitoringEnabled)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: h.defaults)
        for _ in 0..<1000 { if h.monitor.scheduledIntervalMinutes == nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNil(h.monitor.scheduledIntervalMinutes)
    }
    @MainActor func testMalformedIntervalAndThresholdPreferencesHaveBoundedBehavior() async {
        let h = MonitorHarness(); defer { h.close() }
        h.defaults.set(Int.max, forKey: SettingsKeys.pollIntervalMinutes)
        h.defaults.set(Int.max, forKey: SettingsKeys.alertTempThreshold)
        await h.monitor.start(); XCTAssertEqual(h.monitor.scheduledIntervalMinutes, 60)
        await h.read(temperature: 70); XCTAssertEqual(h.notifications.count("temperature"), 0)
        h.defaults.set(Int.min, forKey: SettingsKeys.pollIntervalMinutes); h.monitor.preferencesChanged(refresh: false)
        XCTAssertEqual(h.monitor.scheduledIntervalMinutes, 1)
        await h.read(temperature: 90); XCTAssertEqual(h.notifications.count("temperature"), 1)
    }
    @MainActor func testMonitoringOffAtLaunchReopenManualRefreshAndTickNeverRequestsOrSends() async {
        let h = MonitorHarness(enabled: false); defer { h.close() }
        h.notifications.status = .notDetermined
        await h.monitor.start(); await h.monitor.start(); await h.read(warning: [.mediaReadOnly]); await h.monitor.tick()
        XCTAssertEqual(h.notifications.permissionCalls, 0); XCTAssertTrue(h.notifications.sent.isEmpty)
        XCTAssertTrue(h.monitor.pendingAlerts.isEmpty)
        let enumerations = await h.hardware.enumerations; XCTAssertEqual(enumerations, 1)
    }
    @MainActor func testFirstHotReadingAlertsOnceThenOnlyAfterCoolingAndHeating() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start()
        await h.read(); await h.monitor.evaluateAlerts(); await h.read()
        XCTAssertEqual(h.notifications.count("temperature"), 1)
        await h.read(temperature: 40); await h.read()
        XCTAssertEqual(h.notifications.count("temperature"), 2)
    }
    @MainActor func testFirstFailingReadingAlertsAndBackupReminderIsDeduplicated() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start()
        await h.read(temperature: 40, warning: [.mediaReadOnly]); await h.read(temperature: 40, warning: [.mediaReadOnly])
        XCTAssertEqual(h.notifications.count("failing"), 1); XCTAssertEqual(h.notifications.count("backup"), 1)
        XCTAssertNotNil(h.defaults.object(forKey: SettingsKeys.backupReminderPrefix + h.store.snapshots[0].identity.key))
    }
    @MainActor func testUnavailableHealthBaselineDoesNotSuppressFirstKnownFailure() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start()
        await h.read(temperature: 40, mode: .unavailableHealth)
        XCTAssertEqual(h.store.snapshots[0].health?.rating, .unknown)
        await h.read(temperature: 40, warning: [.mediaReadOnly])
        XCTAssertEqual(h.notifications.count("failing"), 1)
    }
    @MainActor func testFailedSleepingExpiredFutureAndUnknownTemperatureDoNotCreateHeatEvents() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start(); await h.read(temperature: 40)
        await h.read(mode: .failed); XCTAssertTrue(h.store.snapshots[0].isStale)
        await h.read(mode: .sleeping); XCTAssertTrue(h.store.snapshots[0].skippedWhileSleeping)
        await h.read(stamp: h.clock.date.addingTimeInterval(-300))
        await h.read(stamp: h.clock.date.addingTimeInterval(60))
        await h.read(temperature: nil)
        XCTAssertEqual(h.notifications.count("temperature"), 0)
        await h.read(); XCTAssertEqual(h.notifications.count("temperature"), 1)
    }
    @MainActor func testThresholdChangeWaitsForNewReadingAndTemperatureOffDoesNotAlert() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start(); await h.read(temperature: 55)
        h.defaults.set(50, forKey: SettingsKeys.alertTempThreshold); h.monitor.preferencesChanged(refresh: false)
        await h.monitor.evaluateAlerts(); XCTAssertEqual(h.notifications.count("temperature"), 0)
        await h.read(temperature: 55); await h.read(temperature: 55)
        XCTAssertEqual(h.notifications.count("temperature"), 1)
        h.defaults.set(0, forKey: SettingsKeys.alertTempThreshold); h.monitor.preferencesChanged(refresh: false)
        await h.read(); XCTAssertEqual(h.notifications.count("temperature"), 1)
    }
    @MainActor func testReenableWaitsForNewReadingAndAlertsAlreadyHotDriveAgain() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start(); await h.read()
        h.defaults.set(false, forKey: SettingsKeys.monitoringEnabled); h.monitor.preferencesChanged(refresh: false)
        await h.read(); XCTAssertEqual(h.notifications.count("temperature"), 1)
        h.clock.advance(); h.defaults.set(true, forKey: SettingsKeys.monitoringEnabled); h.monitor.preferencesChanged(refresh: false)
        await h.monitor.evaluateAlerts(); XCTAssertEqual(h.notifications.count("temperature"), 1)
        await h.read(); XCTAssertEqual(h.notifications.count("temperature"), 2)
    }
    @MainActor func testDeniedPermissionIsVisibleAndPendingEventRetriesWithoutDuplication() async {
        let h = MonitorHarness(); defer { h.close() }; h.notifications.status = .denied; await h.monitor.start()
        await h.read(); await h.read(); XCTAssertEqual(h.monitor.notificationAccess, .denied)
        XCTAssertEqual(h.monitor.pendingAlerts.filter { $0.category == "temperature" }.count, 1)
        XCTAssertEqual(h.notifications.permissionCalls, 0); XCTAssertTrue(h.notifications.sent.isEmpty)
        h.notifications.status = .allowed; await h.monitor.retryNotifications(); await h.monitor.retryNotifications()
        XCTAssertEqual(h.notifications.count("temperature"), 1); XCTAssertTrue(h.monitor.pendingAlerts.isEmpty)
    }
    @MainActor func testDeliveryFailurePreservesIDsAndOnlyMarksBackupReminderAfterAcceptance() async {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start(); h.notifications.failSend = true
        await h.read(temperature: 40, warning: [.mediaReadOnly])
        XCTAssertNotNil(h.monitor.deliveryError); XCTAssertTrue(h.notifications.sent.isEmpty)
        let pendingIDs = h.monitor.pendingAlerts.map(\.id), key = SettingsKeys.backupReminderPrefix + h.store.snapshots[0].identity.key
        XCTAssertNil(h.defaults.object(forKey: key)); XCTAssertEqual(pendingIDs.count, 2)
        h.notifications.failSend = false; await h.monitor.retryNotifications(); await h.monitor.retryNotifications()
        XCTAssertEqual(h.notifications.sent.map(\.id), pendingIDs); XCTAssertNil(h.monitor.deliveryError)
        XCTAssertNotNil(h.defaults.object(forKey: key)); XCTAssertTrue(h.monitor.pendingAlerts.isEmpty)
    }
    @MainActor func testPermissionRequestErrorIsVisibleAndCanRetry() async {
        let h = MonitorHarness(); defer { h.close() }; h.notifications.status = .notDetermined; h.notifications.failPermission = true
        await h.monitor.start(); XCTAssertNotNil(h.monitor.authorizationError)
        h.notifications.failPermission = false; await h.monitor.retryNotifications()
        XCTAssertNil(h.monitor.authorizationError); XCTAssertEqual(h.monitor.notificationAccess, .allowed)
        XCTAssertEqual(h.notifications.permissionCalls, 2)
    }
    @MainActor func testDisableWhileAuthorizationCheckIsSuspendedPreventsRequestAndDelivery() async throws {
        let h = MonitorHarness(); defer { h.notifications.release(); h.close() }; await h.monitor.start()
        h.notifications.status = .notDetermined; h.notifications.holdAccess = true
        let read = Task { await h.read() }
        for _ in 0..<1000 { if h.notifications.held != nil { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertNotNil(h.notifications.held)
        h.defaults.set(false, forKey: SettingsKeys.monitoringEnabled); h.monitor.preferencesChanged(refresh: false)
        h.notifications.release(); await read.value
        XCTAssertEqual(h.notifications.permissionCalls, 0); XCTAssertTrue(h.notifications.sent.isEmpty)
        XCTAssertTrue(h.monitor.pendingAlerts.isEmpty)
    }
    @MainActor func testManualRefreshInvokesMonitorWithoutTimerEntryPoint() async throws {
        let h = MonitorHarness(); defer { h.close() }; await h.monitor.start()
        h.clock.advance(); await h.hardware.set(stamp: h.clock.date)
        await h.store.refresh()
        for _ in 0..<1000 { if h.notifications.count("temperature") == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(h.notifications.count("temperature"), 1)
    }
}
