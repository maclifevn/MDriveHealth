/*
 * DriveStore.swift — observable state: discovered drives + latest readings.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import MDriveHealthCore

protocol IOErrorScanning: Sendable {
    func scan(withinMinutes: Int) async throws -> IOErrorScan
}
struct SystemIOErrorScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { try await IOErrorWatcher.scan(withinMinutes: withinMinutes) }
}

/// Everything the UI knows about one drive.
struct DriveSnapshot: Identifiable, Sendable {
    let drive: DriveInfo
    var reading: DriveReading?
    var health: HealthReport?
    var previousHistory: HistoryPoint?
    var lastError: String?
    var lastUpdated: Date?
    /// The latest probe failed; `reading`/`health` are carried over from the
    /// last successful one.
    var isStale = false
    /// A background poll skipped this spun-down drive to let it sleep.
    var skippedWhileSleeping = false
    /// Mounted volumes on this drive (available even without SMART).
    var volumes: [VolumeUsage] = []

    var isProbing = false
    var probeStalled = false
    var identityOverride: DriveIdentity?
    var identity: DriveIdentity { identityOverride ?? DriveIdentity.resolve(for: drive, reading: reading) }
    var id: UInt64 { drive.id }
}

@MainActor
@Observable
final class DriveStore {
    private(set) var snapshots: [DriveSnapshot] = []
    private(set) var isRefreshing = false
    @ObservationIgnored private var refreshTaskActive = false
    private(set) var lastRefresh: Date?
    /// Changes after a fleet persistence attempt settles. SMART publication
    /// intentionally happens earlier; history views must query after commit.
    private(set) var historyRevision = UUID()
    private(set) var refreshError: String?
    var showVirtualDrives = false
    /// Set by notifications / the menu bar to select a drive in the main
    /// window; ContentView consumes and clears it.
    var pendingSelection: UInt64?
    var pendingIdentitySelection: String?
    var selectionError: String?
    /// A disk benchmark is running; background SMART polling pauses so its
    /// I/O does not skew the measurement.
    var benchmarkInProgress: Bool { operations.isMeasuring }
    let operations: DriveOperations
    let workspaces: WorkspaceRecoveryController
    let measurementRecovery: MeasurementRecoveryController

    let history: HistoryAccess
    let selfTests: SelfTestController
    private let ioScanner: any IOErrorScanning
    private let hardware: any DriveHardwareServing
    private let trimCommands: any SystemCommandRunning
    @ObservationIgnored var onFreshFleet: (@MainActor () -> Void)?
    @ObservationIgnored private var selfTestPolling: Task<Void, Never>?
    @ObservationIgnored private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
    init(history: HistoryAccess, ioScanner: any IOErrorScanning = SystemIOErrorScanner(), hardware: any DriveHardwareServing = SystemDriveHardware(), measurementRecovery: any MeasurementRecovering = SystemMeasurementRecovery(), trimCommands: any SystemCommandRunning = SupervisedSystemCommands()) {
        let operations = DriveOperations(); self.operations = operations
        self.workspaces = WorkspaceRecoveryController(operations: operations, hardware: hardware)
        self.history = history; self.ioScanner = ioScanner; self.hardware = hardware
        self.trimCommands = trimCommands
        self.measurementRecovery = MeasurementRecoveryController(history: history, service: measurementRecovery)
        self.selfTests = SelfTestController(history: history)
    }
    convenience init() { self.init(history: HistoryAccess()) }
    private var ambiguousIdentityKeys: Set<String> = []

    func retryHistory() async {
        do { try await history.connect(retry: true); await refresh() }
        catch { /* HistoryAccess keeps the actionable opening error. */ }
        measurementRecovery.requestRefresh()
    }

    /// Kernel-log I/O errors seen in the last 24h, keyed by BSD name.
    private(set) var ioErrorCounts: [String: Int] = [:]
    private(set) var isIOScanning = false
    private(set) var ioScanIssue: String?
    private(set) var lastSuccessfulIOScan: Date?

    /// Snapshots the sidebar shows, honoring the virtual-drive filter.
    var visibleSnapshots: [DriveSnapshot] {
        showVirtualDrives ? snapshots : snapshots.filter { !$0.drive.isVirtual }
    }

    var internalDrives: [DriveSnapshot] { visibleSnapshots.filter { $0.drive.isInternal } }
    var externalDrives: [DriveSnapshot] { visibleSnapshots.filter { !$0.drive.isInternal } }

    /// Streaming publication is suitable for display, but durable routing
    /// waits until every attached drive can participate in collision checks.
    func notificationTarget(for key: String) -> UInt64? {
        guard !isRefreshing, refreshError == nil else { return nil }
        return DriveIdentity.matchingRegistryID(forKey: key, in: snapshots.map { ($0.id, $0.identity) })
    }

    /// The worst health rating across all probed drives (drives the app badge).
    var worstRating: HealthRating? {
        snapshots.compactMap { $0.health?.rating }.max()
    }

    /// Re-enumerates and probes all drives. Background polls pass
    /// `wakingSleepingDrives: false` so spun-down HDDs keep sleeping; manual
    /// refreshes always read everything.
    func refresh(wakingSleepingDrives: Bool = true) async {
        guard !refreshTaskActive, !benchmarkInProgress, !operations.isShuttingDown else { return }
        refreshTaskActive = true; operations.beginFleetResolution()
        isRefreshing = true
        defer {
            isRefreshing = false; refreshTaskActive = false; operations.endFleetResolution()
            let waiters = refreshWaiters; refreshWaiters.removeAll(); for waiter in waiters { waiter.resume() }
        }
        let drives: [DriveInfo]
        let discovery: DriveOperations.Lease
        do { discovery = try operations.begin(driveID: nil, kind: .discovery) }
        catch { refreshError = error.localizedDescription; return }
        do {
            drives = try await hardware.enumerate()
            guard drives.count <= 512, Set(drives.map(\.id)).count == drives.count else { throw HardwareWorkerError.protocolViolation }
            operations.end(discovery)
        } catch {
            operations.fail(discovery, error: error)
            refreshError = error.localizedDescription
            for index in snapshots.indices { snapshots[index].isStale = true }
            return // Preserve the last fleet when enumeration is unavailable.
        }
        guard !Task.isCancelled else { return }
        let previous = snapshots
        snapshots = drives.map { drive in
            if var old = previous.first(where: { $0.drive == drive }) {
                old.isProbing = true; old.isStale = old.reading != nil || !old.volumes.isEmpty
                old.lastError = nil; old.skippedWhileSleeping = false
                return old
            }
            var pending = DriveSnapshot(drive: drive); pending.isProbing = true; return pending
        }
        refreshError = nil
        // Start at most three workers and publish each result immediately.
        await withTaskGroup(of: DriveSnapshot.self) { group in
            var next = 0
            func addNext() {
                guard next < drives.count, !Task.isCancelled else { return }
                let drive = drives[next]; next += 1
                group.addTask { await self.probeSnapshot(drive, wakingSleepingDrives: wakingSleepingDrives) }
            }
            for _ in 0..<min(3, drives.count) { addNext() }
            for await snapshot in group {
                if let index = snapshots.firstIndex(where: { $0.drive == snapshot.drive }) {
                    var candidates = snapshots; candidates[index] = snapshot
                    snapshots = resolvedFleet(fresh: candidates, previous: snapshots)
                }
                addNext()
            }
        }
        for index in snapshots.indices where snapshots[index].isProbing {
            snapshots[index].isProbing = false
            snapshots[index].lastError = DriveOperationError.cancelled.localizedDescription
        }
        snapshots = resolvedFleet(fresh: snapshots, previous: previous)
        lastRefresh = Date()
        // History waits for fleet identity resolution; this never delays the
        // individual SMART results published above or writes a shared serial
        // key before a later worker reveals its duplicate.
        let freshFleet = snapshots
        launchBackground { await self.persistFleet(freshFleet) }
        pruneHistoryOccasionally()
        launchBackground { await self.refreshIOErrors(for: drives.map(\.bsdName)) }
        isRefreshing = false
        selfTests.retainAttachedKeys(Set(snapshots.map { $0.identity.key }))
        operations.retainAttachedFirmwareTests(Set(snapshots.map(\.id)))
        // Restore ownership before any READ LOG attempt: a blocked log or a
        // sleeping drive must not hide a previously accepted/pending run.
        for snapshot in snapshots where snapshot.drive.smartInterface == .ata && snapshot.identity.isPersistent {
            do {
                try await restoreSelfTest(snapshot)
            } catch { selfTests.report(error, key: snapshot.identity.key) }
        }
        scheduleSelfTestPolling()
        await pollSelfTests()
        workspaces.updateFleet(snapshots)
        measurementRecovery.requestRefresh()
        onFreshFleet?()
    }

    private func probeSnapshot(_ drive: DriveInfo, wakingSleepingDrives: Bool) async -> DriveSnapshot {
        var snapshot = DriveSnapshot(drive: drive)
        let lease: DriveOperations.Lease
        do {
            try Task.checkCancellation()
            lease = try await operations.beginRead(driveID: drive.id, kind: .probe)
        } catch { snapshot.lastError = error.localizedDescription; return snapshot }
        do {
            let result = try await hardware.inspect(drive, avoidWakingIdle: !wakingSleepingDrives)
            snapshot.volumes = result.volumes; snapshot.reading = result.reading
            snapshot.skippedWhileSleeping = result.skippedAsleep
            if let reading = result.reading {
                snapshot.health = reading.evaluateHealth(); snapshot.lastUpdated = reading.capturedAt
                operations.observe(reading, driveID: drive.id)
            }
            operations.end(lease)
        } catch {
            operations.fail(lease, error: error)
            snapshot.lastError = error.localizedDescription
            if let command = error as? CommandError { snapshot.probeStalled = command.reason == .timedOut || command.pendingChild != nil }
        }
        return snapshot
    }

    private func persistFleet(_ fleet: [DriveSnapshot]) async {
        defer { historyRevision = UUID() }
        guard await history.prepareConnection() else { return }
        for snapshot in fleet {
            guard !snapshot.isStale, !snapshot.skippedWhileSleeping,
                  let reading = snapshot.reading, let health = snapshot.health else { continue }
            let key = snapshot.identity.key, bsdName = snapshot.drive.bsdName
            guard !ambiguousIdentityKeys.contains(key) else { continue }
            do {
                let previous = try await history.run("snapshot.latest:" + key) { try await $0.latest(driveKey: key) }
                if let index = snapshots.firstIndex(where: { $0.drive == snapshot.drive && $0.identity.key == key && $0.lastUpdated == snapshot.lastUpdated }) {
                    snapshots[index].previousHistory = previous
                }
            } catch { /* HistoryAccess retains the operation issue. */ }
            guard !ambiguousIdentityKeys.contains(key) else { continue }
            do { try await history.run("snapshot.record:" + key) { try await $0.record(driveKey: key, bsdName: bsdName, reading: reading, health: health) } }
            catch { /* SMART stays visible while HistoryAccess exposes the save error. */ }
        }
    }

    func prepareMeasurement(_ drive: DriveInfo, lease: DriveCommandLock.Lease, cancelled: @Sendable () -> Bool) async throws {
        if cancelled() { throw DriveOperationError.cancelled }
        let status = try await hardware.measurementStatus(drive, lease: lease)
        if drive.smartInterface == .ata {
            guard let inspection = status else { throw HardwareWorkerError.selfTestUnavailable }
            if let reading = inspection.reading { operations.observe(reading, driveID: drive.id) }
            guard let status = inspection.reading?.ataSelfTest else { throw HardwareWorkerError.selfTestUnavailable }
            guard !status.inProgress else { throw HardwareWorkerError.selfTestRunning }
        }
        if cancelled() { throw DriveOperationError.cancelled }
    }

    func readSelfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] {
        if let snapshot = snapshots.first(where: { $0.drive == drive }), snapshot.identity.isPersistent {
            return try await observeSelfTest(drive).log.entries
        }
        let lease = try await operations.beginRead(driveID: drive.id, kind: .selfTestLog)
        do { let result = try await hardware.selfTestLog(drive); operations.end(lease); return result }
        catch { operations.fail(lease, error: error); throw error }
    }
    func startSelfTest(_ drive: DriveInfo, extended: Bool) async throws {
        let lease = try operations.begin(driveID: drive.id, kind: .selfTestStart)
        var diskLock: DriveCommandLock.Lease?
        var command: SelfTestCommand?
        var key: String?
        var dispatched = false
        do {
            let snapshot = try selfTestTarget(drive); key = snapshot.identity.key
            try selfTests.begin(snapshot.identity.key)
            defer { selfTests.end(snapshot.identity.key) }
            // Durable storage is a prerequisite, not a best-effort side effect.
            try await history.connect()
            diskLock = try await DriveCommandLock.acquireAsync(registryEntryID: drive.id)
            let observation = try await hardware.selfTestObservation(drive, lease: diskLock!, avoidWakingIdle: false)
            try validateSelfTestObservation(observation, drive: drive, key: snapshot.identity.key)
            operations.observe(.ata(observation.reading), driveID: drive.id)
            guard observation.reading.selfTestSupported == true, let status = observation.reading.selfTest else { throw HardwareWorkerError.selfTestUnavailable }
            guard !status.inProgress else { throw HardwareWorkerError.selfTestRunning }
            try await selfTests.observe(key: snapshot.identity.key, model: drive.model, observation: observation)
            command = try await selfTests.prepare(key: snapshot.identity.key, model: drive.model,
                                                 kind: extended ? .extended : .short, baseline: observation.log)
            try await selfTests.markPending(command!, model: drive.model)
            operations.trackSelfTest(driveID: drive.id, active: true)
            try Task.checkCancellation()
            _ = try selfTestTarget(drive) // Recheck after awaiting journal writes.
            dispatched = true
            let receipt = try await hardware.dispatchSelfTest(drive, command: command!, lease: diskLock!)
            operations.confirmedSelfTestStart(driveID: drive.id)
            try await selfTests.markAccepted(command!, receipt: receipt, model: drive.model)
            diskLock?.release(); operations.end(lease); scheduleSelfTestPolling()
        } catch {
            let notIssued: Bool
            if case SelfTestCommandError.notIssued = error { notIssued = true } else { notIssued = !dispatched }
            if let command, notIssued {
                do { try await selfTests.reject(command, model: drive.model) }
                catch { selfTests.report(error, key: command.driveKey) }
            }
            if !notIssued { operations.confirmedSelfTestStart(driveID: drive.id); scheduleSelfTestPolling() }
            if let key { selfTests.report(error, key: key) }
            if let key { operations.trackSelfTest(driveID: drive.id, active: selfTests.states[key]?.state.activeRun != nil) }
            if let pending = (error as? CommandError)?.pendingChild { operations.retainUntilExit(lease, pending: pending, diskLock: diskLock) }
            else { diskLock?.release(); operations.end(lease) }
            throw error
        }
    }
    private func selfTestTarget(_ drive: DriveInfo) throws -> DriveSnapshot {
        guard !isRefreshing, refreshError == nil, drive.smartInterface == .ata,
              let snapshot = snapshots.first(where: { $0.drive == drive }), snapshot.identity.isPersistent,
              notificationTarget(for: snapshot.identity.key) == drive.id else { throw HardwareWorkerError.deviceChanged }
        return snapshot
    }
    private func restoreSelfTest(_ snapshot: DriveSnapshot) async throws {
        let key = snapshot.identity.key
        let lease = try await operations.beginRead(driveID: snapshot.id, kind: .selfTestLog)
        defer { operations.end(lease) }
        guard try selfTestTarget(snapshot.drive).identity.key == key else { throw HardwareWorkerError.deviceChanged }
        try selfTests.begin(key); defer { selfTests.end(key) }
        try await selfTests.restore(key: key, model: snapshot.drive.model)
        guard try selfTestTarget(snapshot.drive).identity.key == key else { throw HardwareWorkerError.deviceChanged }
        operations.trackSelfTest(driveID: snapshot.id, active: selfTests.states[key]?.state.activeRun != nil)
    }
    private func validateSelfTestObservation(_ observation: SelfTestObservation, drive: DriveInfo, key: String) throws {
        try observation.validate()
        guard DriveIdentity.resolve(for: drive, reading: .ata(observation.reading)).key == key,
              try selfTestTarget(drive).identity.key == key else { throw HardwareWorkerError.deviceChanged }
    }
    @discardableResult func observeSelfTest(_ drive: DriveInfo, avoidWakingIdle: Bool = false, closeWithoutResult: Bool = false) async throws -> SelfTestObservation {
        let snapshot = try selfTestTarget(drive), key = snapshot.identity.key
        let lease = try await operations.beginRead(driveID: drive.id, kind: .selfTestLog)
        var diskLock: DriveCommandLock.Lease?
        do {
            try selfTests.begin(key); defer { selfTests.end(key) }
            diskLock = try await DriveCommandLock.acquireAsync(registryEntryID: drive.id)
            let observation = try await hardware.selfTestObservation(drive, lease: diskLock!, avoidWakingIdle: avoidWakingIdle)
            try validateSelfTestObservation(observation, drive: drive, key: key)
            // Fresh firmware ownership must survive a later journal failure.
            operations.observe(.ata(observation.reading), driveID: drive.id)
            if closeWithoutResult { try await selfTests.finishWithoutResult(key: key, model: drive.model, observation: observation) }
            else { try await selfTests.observe(key: key, model: drive.model, observation: observation) }
            operations.trackSelfTest(driveID: drive.id, active: selfTests.states[key]?.state.activeRun != nil)
            diskLock?.release(); operations.end(lease)
            if closeWithoutResult { onFreshFleet?() }
            scheduleSelfTestPolling(); return observation
        } catch {
            selfTests.report(error, key: key)
            if let pending = (error as? CommandError)?.pendingChild { operations.retainUntilExit(lease, pending: pending, diskLock: diskLock) }
            else { diskLock?.release(); operations.end(lease) }
            throw error
        }
    }
    /// Runs independently of the tab and notification preference. Sleeping or
    /// stale drives are never awakened by this background journal poll.
    func pollSelfTests(activeOnly: Bool = false) async {
        guard !operations.isShuttingDown else { return }
        let candidates = snapshots.filter { snapshot in
            guard case .ata(let reading) = snapshot.reading else { return false }
            return snapshot.drive.smartInterface == .ata && snapshot.identity.isPersistent && !snapshot.isStale && !snapshot.isProbing
                && !snapshot.skippedWhileSleeping && snapshot.lastError == nil && reading.selfTestSupported != false
                && (!activeOnly || selfTests.states[snapshot.identity.key]?.state.activeRun != nil)
        }
        for snapshot in candidates {
            guard !Task.isCancelled, !isRefreshing, !benchmarkInProgress else { return }
            do { _ = try await observeSelfTest(snapshot.drive, avoidWakingIdle: true) }
            catch { /* Per-drive tracking issue remains visible and retryable. */ }
        }
    }
    private func scheduleSelfTestPolling() {
        guard !operations.isShuttingDown, selfTestPolling == nil, selfTests.states.values.contains(where: { $0.state.activeRun != nil }) else { return }
        selfTestPolling = Task { [weak self] in
            defer { self?.selfTestPolling = nil }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self, self.selfTests.states.values.contains(where: { $0.state.activeRun != nil }) else { return }
                await self.pollSelfTests(activeOnly: true)
                self.onFreshFleet?()
            }
        }
    }
    func eject(_ drive: DriveInfo, volumes: [VolumeUsage], force: Bool,
               runner: any SystemCommandRunning = SupervisedSystemCommands()) async -> EjectOutcome {
        let lease: DriveOperations.Lease
        do { lease = try operations.begin(driveID: drive.id, kind: .eject) }
        catch { return .failed(error.localizedDescription) }
        var diskLock: DriveCommandLock.Lease?
        do {
            diskLock = try await DriveCommandLock.acquireAsync(registryEntryID: drive.id)
            try await hardware.validate(drive)
            try Task.checkCancellation()
            let result = await EjectService.eject(drive: drive, volumes: volumes, force: force, runner: runner)
            if case .stalled(_, let pending) = result { operations.retainUntilExit(lease, pending: pending, diskLock: diskLock) }
            else { diskLock?.release(); operations.end(lease) }
            return result
        } catch {
            if let pending = (error as? CommandError)?.pendingChild { operations.retainUntilExit(lease, pending: pending, diskLock: diskLock) }
            else { diskLock?.release(); operations.end(lease) }
            return .failed(error.localizedDescription)
        }
    }

    private func auxiliary<T>(driveID: UInt64? = nil, kind: DriveOperationKind,
                               _ work: () async throws -> T) async throws -> T {
        let lease = try await operations.beginRead(driveID: driveID, kind: kind)
        do { let value = try await work(); operations.end(lease); return value }
        catch { operations.fail(lease, error: error); throw error }
    }
    func readBridge(_ drive: DriveInfo) async throws -> USBBridgeInfo? {
        try await auxiliary(driveID: drive.id, kind: .bridge) { try await hardware.bridge(drive) }
    }
    func readTrimSupport(_ drive: DriveInfo) async throws -> Bool? {
        try await auxiliary(kind: .trim) { try await TrimStatusReader.lookupSupport(bsdName: drive.bsdName, runner: trimCommands) }
    }
    func readBattery() async throws -> BatteryInfo? { try await auxiliary(kind: .battery) { try await hardware.battery() } }
    func readSensors() async throws -> [TemperatureSensor] { try await auxiliary(kind: .sensors) { try await hardware.sensors() } }
    func readMemory() async throws -> MemoryStats? { try await auxiliary(kind: .memory) { try await hardware.memory() } }

    /// Merge cached readings before collision detection: a failed probe must
    /// not conceal a duplicate SMART serial on another attached drive.
    func resolvedFleet(fresh candidates: [DriveSnapshot], previous: [DriveSnapshot]) -> [DriveSnapshot] {
        var fresh = merged(fresh: candidates, previous: previous)
        let candidates = fresh.map { ($0.drive, $0.identity) }
        for group in Dictionary(grouping: candidates, by: { $0.1.key }).values where group.count > 1 {
            ambiguousIdentityKeys.insert(group[0].1.key)
        }
        let identities = DriveIdentity.isolatedFleet(candidates, knownAmbiguousKeys: ambiguousIdentityKeys)
        for index in fresh.indices {
            let identity = identities[fresh[index].id]
            if identity?.key != fresh[index].identity.key { fresh[index].previousHistory = nil }
            fresh[index].identityOverride = identity
        }
        return fresh
    }

    /// A transient probe failure (or a skipped sleeping drive) keeps the last
    /// good reading on screen instead of blanking the UI.
    func merged(fresh: [DriveSnapshot],
                        previous: [DriveSnapshot]) -> [DriveSnapshot] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) },
                                      uniquingKeysWith: { first, _ in first })
        return fresh.map { snapshot in
            guard snapshot.reading == nil,
                  snapshot.skippedWhileSleeping || snapshot.lastError != nil,
                  let old = previousByID[snapshot.id], old.reading != nil || !old.volumes.isEmpty,
                  old.drive == snapshot.drive
            else { return snapshot }
            var carried = snapshot
            carried.identityOverride = old.identity
            if carried.volumes.isEmpty { carried.volumes = old.volumes }
            carried.reading = old.reading
            carried.health = old.health
            carried.previousHistory = old.previousHistory
            carried.lastUpdated = old.lastUpdated
            carried.isStale = !snapshot.skippedWhileSleeping
            return carried
        }
    }

    private var lastIOScan: Date?
    /// Rolling 24h window of kernel I/O error events, fed by incremental scans.
    /// The window/merge/count algorithm lives in core `IOErrorMonitor`; this
    /// only owns the cadence and the off-main scan.
    private var ioErrorEvents: [IOErrorEvent] = []

    func retryIOErrors() async {
        await refreshIOErrors(for: snapshots.map(\.drive.bsdName), force: true)
    }

    /// Failed/partial scans retain an incomplete status and do not claim the
    /// successful cadence slot. Event storage has both count and byte budgets.
    func refreshIOErrors(for bsdNames: [String], force: Bool = false) async {
        guard !isIOScanning, !benchmarkInProgress else { return }
        let now = Date()
        guard let minutes = force ? 1440 : IOErrorMonitor.scanMinutes(lastScan: lastIOScan, now: now) else { return }
        let lease: DriveOperations.Lease
        do { lease = try operations.begin(driveID: nil, kind: .kernelLog) }
        catch { return }
        isIOScanning = true
        defer { isIOScanning = false }
        do {
            let scan = try await ioScanner.scan(withinMinutes: minutes)
            let known = ioErrorEvents
            let window = try await Task.detached(priority: .utility) {
                try IOErrorMonitor.boundedMerge(known: known, fresh: scan.events, now: Date())
            }.value
            operations.end(lease)
            ioErrorEvents = window.events
            ioErrorCounts = IOErrorMonitor.counts(events: window.events, bsdNames: bsdNames)
            if scan.isComplete && window.discarded == 0 {
                ioScanIssue = nil; lastIOScan = now; lastSuccessfulIOScan = Date()
            } else {
                ioScanIssue = String(localized: "ioScan.partial",
                    defaultValue: "Kết quả quét chưa đầy đủ: \(scan.diagnostics.malformedLines) dòng sai định dạng, \(scan.diagnostics.invalidTimestamps) timestamp không hợp lệ, \(window.discarded) sự kiện vượt giới hạn lưu trữ.")
            }
        } catch {
            operations.fail(lease, error: error)
            // Keep only still-valid cached events; missing fresh data is unknown.
            ioErrorEvents = IOErrorMonitor.merge(known: ioErrorEvents, fresh: [], now: Date())
            ioErrorCounts = IOErrorMonitor.counts(events: ioErrorEvents, bsdNames: bsdNames)
            ioScanIssue = error.localizedDescription
        }
    }

    private var lastPrune: Date?
    private var isPruning = false

    private func pruneHistoryOccasionally() {
        guard !operations.isShuttingDown else { return }
        // Keep 12 months of history; prune at most once per app day. The
        // DELETE runs off-main — it can touch a year of rows.
        if let lastPrune, Date().timeIntervalSince(lastPrune) < 86_400 { return }
        guard !isPruning else { return }
        isPruning = true
        let cutoff = Date().addingTimeInterval(-365 * 86_400)
        launchBackground {
            defer { self.isPruning = false }
            do {
                try await self.history.run("prune") { try await $0.pruneOlderThan(cutoff) }
                self.lastPrune = Date()
            } catch { /* Keep lastPrune unchanged so a failed prune is retried. */ }
        }
    }
    private func launchBackground(_ work: @escaping @MainActor () async -> Void) {
        guard !operations.isShuttingDown else { return }
        let id = UUID()
        backgroundTasks[id] = Task { [self] in
            defer { backgroundTasks.removeValue(forKey: id) }
            await work()
        }
    }
    func beginShutdown() { operations.beginShutdown(); selfTestPolling?.cancel(); workspaces.beginShutdown(); measurementRecovery.beginShutdown() }
    func waitForBackgroundWork() async {
        await workspaces.waitForCompletion()
        if refreshTaskActive { await withCheckedContinuation { refreshWaiters.append($0) } }
        if let selfTestPolling { await selfTestPolling.value }
        while !backgroundTasks.isEmpty { for task in Array(backgroundTasks.values) { await task.value } }
        await measurementRecovery.waitForCompletion()
    }
    func resumeAfterShutdown() { operations.resumeAfterShutdown(); workspaces.resumeAfterShutdown(); measurementRecovery.resumeAfterShutdown(); scheduleSelfTestPolling() }
}
