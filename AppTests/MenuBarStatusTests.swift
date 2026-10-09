/* Cached data must remain distinguishable from current menu status. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private actor MenuStatusHardware: DriveHardwareServing {
    let drives: [DriveInfo]
    var mode = "current"
    private(set) var enumerationCalls = 0
    init(_ drives: [DriveInfo]) { self.drives = drives }
    func set(_ mode: String) { self.mode = mode }
    func enumerate() async throws -> [DriveInfo] {
        enumerationCalls += 1
        if mode == "discovery-failed" { throw HardwareWorkerError.remote("private discovery failed") }
        return mode == "empty" ? [] : drives
    }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection {
        if mode == "probe-failed" { throw HardwareWorkerError.remote("private SMART read failed") }
        if mode == "sleeping" { return .init(reading: nil, skippedAsleep: true, volumes: []) }
        guard drive.smartInterface != .unsupported else { return .init(reading: nil, skippedAsleep: false, volumes: []) }
        return .init(reading: menuStatusReading(drive), skippedAsleep: false, volumes: [])
    }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
}

private func menuStatusReading(_ drive: DriveInfo) -> DriveReading {
    .nvme(.init(controller: .init(model: drive.model, serialNumber: drive.serialNumber ?? "", firmwareRevision: "F", ieeeOUI: "00-00-00",
                                 controllerID: 0, specVersion: "1.3", totalCapacityBytes: drive.sizeBytes, unallocatedCapacityBytes: 0,
                                 warningTempKelvin: 357, criticalTempKelvin: 373, namespaceCount: 1),
                smart: .init(capturedAt: Date(), criticalWarning: [], temperatureKelvin: 310, availableSpare: 100,
                             availableSpareThreshold: 10, percentageUsed: 4, dataUnitsRead: 1, dataUnitsWritten: 1,
                             hostReadCommands: 1, hostWriteCommands: 1, controllerBusyTimeMinutes: 1, powerCycles: 1,
                             powerOnHours: 1, unsafeShutdowns: 0, mediaErrors: 0, errorLogEntries: 0,
                             warningTempTimeMinutes: 0, criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [])))
}

private struct MenuStatusScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}

final class MenuBarStatusTests: XCTestCase {
    @MainActor private var fixtures: [(DriveStore, URL)] = []
    override func tearDown() async throws {
        try await closeFixtures()
        try await super.tearDown()
    }
    @MainActor private func closeFixtures() async throws {
        for (store, directory) in fixtures {
            store.beginShutdown(); await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            try await store.history.shutdown()
            try FileManager.default.removeItem(at: directory)
        }
        fixtures.removeAll()
    }
    private func drive(_ id: UInt64 = 901, interconnect: String = "USB", smart: SMARTInterfaceKind = .nvme) -> DriveInfo {
        .init(registryEntryID: id, bsdName: "disk\(id)", model: "Menu fixture \(id)", serialNumber: "MENU-\(id)",
              firmwareRevision: "F", sizeBytes: 1_000_000, interconnect: interconnect, location: "External", isSolidState: true, smartInterface: smart)
    }
    private func snapshot(_ id: UInt64 = 901) -> DriveSnapshot {
        let drive = drive(id), reading = menuStatusReading(drive)
        return .init(drive: drive, reading: reading, health: reading.evaluateHealth(), lastUpdated: reading.capturedAt)
    }
    @MainActor private func store(_ provider: MenuStatusHardware) throws -> DriveStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("menu-status-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let database = directory.appendingPathComponent("history.sqlite")
        let store = DriveStore(history: HistoryAccess(factory: { try HistoryStore(databaseURL: database) }),
                               ioScanner: MenuStatusScanner(), hardware: provider,
                               measurementRecovery: SystemMeasurementRecovery(rootURL: directory.appendingPathComponent("journal")))
        fixtures.append((store, directory)); return store
    }

    func testFreshValuesAreScopedToAvailableReadingsAndUnknownScoreStaysUnknown() {
        let first = snapshot(), unsupported = DriveSnapshot(drive: drive(902, smart: .unsupported))
        var partial = snapshot(903)
        partial.health = .init(score: nil, rating: .unknown, coverage: .partial, lifetimeLeftPercent: nil, issues: [], capturedAt: Date())
        let status = MenuBarStatus(snapshots: [first, unsupported])
        XCTAssertFalse(status.isUnverified); XCTAssertEqual(status.currentSnapshots.count, 1)
        XCTAssertEqual(status.value(for: .temp), "37°"); XCTAssertEqual(status.value(for: .score), "100")
        XCTAssertNil(MenuBarStatus(snapshots: [partial]).value(for: .score))
        XCTAssertTrue(MenuBarStatus(snapshots: [first, partial]).isUnverified)
        XCTAssertNil(status.value(for: .icon)); XCTAssertEqual(status.currentWorstRating, .good)
        XCTAssertEqual(MenuBarStatus.readingState(unsupported), .unsupported)
        var failing = first
        failing.health = .init(score: 0, rating: .failed, coverage: .complete, lifetimeLeftPercent: nil, issues: [], capturedAt: Date())
        let mixed = MenuBarStatus(snapshots: [failing, partial])
        XCTAssertTrue(mixed.isUnverified); XCTAssertEqual(mixed.symbol, "externaldrive.fill.badge.xmark")
        XCTAssertTrue(mixed.accessibilityStatus.contains(HealthRating.failed.displayName))
        XCTAssertTrue(mixed.accessibilityStatus.contains(String(localized: "menubar.unverified", defaultValue: "Chưa xác minh")))
    }

    func testCachedSleepingAndPendingReadingsNeverAppearAsFreshCompactValues() {
        let original = snapshot()
        for state in [MenuBarStatus.ReadingState.previous, .sleeping, .reading] {
            var cached = original
            cached.isStale = state == .previous; cached.skippedWhileSleeping = state == .sleeping; cached.isProbing = state == .reading
            let status = MenuBarStatus(snapshots: [cached])
            XCTAssertEqual(MenuBarStatus.readingState(cached), state)
            XCTAssertTrue(status.isUnverified); XCTAssertNil(status.value(for: .temp)); XCTAssertNil(status.value(for: .score))
            XCTAssertEqual(status.symbol, "exclamationmark.triangle")
            XCTAssertEqual(cached.reading, original.reading); XCTAssertEqual(cached.lastUpdated, original.lastUpdated)
        }
        var failed = DriveSnapshot(drive: drive()); failed.lastError = "failed"
        XCTAssertEqual(MenuBarStatus.readingState(failed), .failed)
        XCTAssertTrue(MenuBarStatus(snapshots: [original, failed]).isUnverified)
    }

    @MainActor func testFailedDiscoveryWithNoFleetIsDistinctFromSuccessfulEmptyDiscovery() async throws {
        let provider = MenuStatusHardware([drive()]), store = try store(provider)
        await provider.set("discovery-failed"); await store.refresh()
        XCTAssertTrue(store.visibleSnapshots.isEmpty); XCTAssertTrue(store.menuBarStatus.discoveryFailed)
        XCTAssertTrue(store.menuBarStatus.isUnverified); XCTAssertTrue(store.menuBarStatus.refreshEnabled)
        XCTAssertNil(store.menuBarStatus.value(for: .score))
        await provider.set("empty"); await store.refresh()
        XCTAssertTrue(store.visibleSnapshots.isEmpty); XCTAssertFalse(store.menuBarStatus.discoveryFailed)
        XCTAssertFalse(store.menuBarStatus.isUnverified); XCTAssertNil(store.menuBarStatus.currentWorstRating)
    }

    @MainActor func testActualProbeAndDiscoveryFailuresKeepPriorReadingUntilConfirmedRecovery() async throws {
        let provider = MenuStatusHardware([drive()]), store = try store(provider)
        await store.refresh(); let first = try XCTUnwrap(store.snapshots.first)
        XCTAssertEqual(store.menuBarStatus.value(for: .temp), "37°")
        for mode in ["discovery-failed", "probe-failed", "sleeping"] {
            await provider.set(mode); await store.refresh(wakingSleepingDrives: false)
            let cached = try XCTUnwrap(store.snapshots.first)
            XCTAssertEqual(cached.reading, first.reading); XCTAssertEqual(cached.lastUpdated, first.lastUpdated)
            XCTAssertTrue(store.menuBarStatus.isUnverified); XCTAssertNil(store.menuBarStatus.value(for: .score))
            XCTAssertEqual(MenuBarStatus.readingState(cached), mode == "sleeping" ? .sleeping : .previous)
        }
        await provider.set("current"); await store.refresh()
        XCTAssertFalse(store.menuBarStatus.isUnverified); XCTAssertEqual(store.menuBarStatus.currentSnapshots.count, 1)
        XCTAssertEqual(store.menuBarStatus.value(for: .score), "100")
        XCTAssertNil(store.refreshError); XCTAssertNil(store.snapshots.first?.lastError)
    }

    @MainActor func testHiddenVirtualDriveCannotAffectVisibleMenuStatus() async throws {
        let provider = MenuStatusHardware([drive(), drive(902, interconnect: "Virtual Interface")]), store = try store(provider)
        await store.refresh()
        XCTAssertEqual(store.snapshots.count, 2); XCTAssertEqual(store.visibleSnapshots.count, 1)
        XCTAssertEqual(store.menuBarStatus.snapshots.map(\.id), [901])
        store.showVirtualDrives = true
        XCTAssertEqual(store.menuBarStatus.snapshots.count, 2)
    }

    @MainActor func testRefreshDisabledDuringMeasurementAndShutdownBeforeProviderDispatch() async throws {
        let provider = MenuStatusHardware([drive()]), store = try store(provider)
        await store.refresh(); let calls = await provider.enumerationCalls
        await store.waitForBackgroundWork(); await store.operations.waitForIdle()
        let lease = try store.operations.begin(driveID: 901, kind: .benchmark)
        XCTAssertFalse(store.menuBarStatus.refreshEnabled); XCTAssertTrue(store.menuBarStatus.isUnverified)
        XCTAssertEqual(store.menuBarStatus.currentSnapshots.count, 0)
        XCTAssertNil(store.menuBarStatus.value(for: .temp)); await store.refresh()
        let during = await provider.enumerationCalls; XCTAssertEqual(during, calls)
        store.operations.end(lease); XCTAssertTrue(store.menuBarStatus.refreshEnabled)
        store.beginShutdown(); XCTAssertFalse(store.menuBarStatus.refreshEnabled)
        await store.refresh(); let after = await provider.enumerationCalls; XCTAssertEqual(after, calls)
        XCTAssertFalse(MenuBarStatus(snapshots: [snapshot()], isRefreshing: true).refreshEnabled)
    }
}
