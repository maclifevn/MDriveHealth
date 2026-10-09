/*
 * BenchmarkRunner.swift — drives DiskBenchmarkEngine from the UI: one run at a
 * time, live progress/samples, persistence, and background-poll suppression.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import MDriveHealthCore

/// Synchronous injection for deterministic tests; production uses MeasurementServing.
protocol BenchmarkOperating: Sendable {
    func run(volume: VolumeUsage, config: BenchmarkConfig,
             isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping DiskBenchmarkEngine.ProgressHandler) throws -> BenchmarkResult
}
extension DiskBenchmarkEngine: BenchmarkOperating {}

@MainActor
@Observable
final class BenchmarkRunner {
    enum State {
        case idle
        case running(BenchmarkPhase)
        case finished(BenchmarkResult)
        case failed(String)              // localized message
    }

    /// One point on the live throughput chart.
    struct SpeedSample: Identifiable {
        let id: Int
        let phase: BenchmarkPhase
        let elapsed: TimeInterval        // seconds since the run started
        let megabytesPerSecond: Double
    }

    private(set) var state: State = .idle
    private(set) var progress: BenchmarkProgress?
    private(set) var samples: [SpeedSample] = []
    // Maintained incrementally per progress tick so the live gauges never
    // have to scan the samples array during a render pass.
    private(set) var lastWriteMBps: Double = 0
    private(set) var lastReadMBps: Double = 0
    private(set) var peakMBps: Double = 0
    private(set) var runningDriveID: UInt64?
    private(set) var runningVolume: VolumeUsage?
    /// Drive the current/most recent run belongs to. Unlike runningDriveID it
    /// SURVIVES finish(), so finished/failed states stay scoped to their
    /// drive's tab instead of leaking onto every drive (cleared by reset()).
    private(set) var ownerDriveID: UInt64?

    struct UnsavedResult: Identifiable {
        let id: UUID
        let result: BenchmarkResult
        let driveKey: String
        let record: MeasurementJobRecord?
        init(id: UUID = UUID(), result: BenchmarkResult, driveKey: String, record: MeasurementJobRecord? = nil) {
            self.id = id; self.result = result; self.driveKey = driveKey; self.record = record
        }
    }
    private(set) var unsavedResults: [UnsavedResult] = []
    private(set) var persistenceError: String?
    private(set) var journalCleanupIssues: [UUID: MeasurementJournalIssue] = [:]
    private(set) var recoveredResultMessage: String?
    private(set) var isSaving = false
    /// Result publication precedes persistence. Views reload saved history
    /// only after the corresponding write attempt has settled.
    private(set) var historyRevision = UUID()
    private let store: DriveStore
    private let engine: (any BenchmarkOperating)?
    private let worker: any MeasurementServing
    private var task: Task<Void, Never>?
    private var cancelFlag: CancelBox?
    private var sampleCounter = 0
    /// Bumped on every start(); progress hops carry their generation so a
    /// straggler Task from a cancelled run can't inject samples into the next.
    private var runGeneration = 0
    private var operationLease: DriveOperations.Lease?
    private var diskLease: DriveCommandLock.Lease?
    private let watchdog: WriteOperationWatchdog
    private(set) var isStalled = false
    private(set) var isCleaning = false
    private(set) var isCancelling = false
    private(set) var measurementID: UUID?
    private(set) var workspaceReviews: [MeasurementWorkspaceReview] = []
    var requiresWorkspaceReview: Bool { !workspaceReviews.isEmpty }
    private var measurementTarget: (UUID, DriveInfo, VolumeUsage, String, MeasurementOrigin)?
    private var measurementBegan = false
    @ObservationIgnored private var activeWork = 0
    @ObservationIgnored private var workWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var savingWaiters: [CheckedContinuation<Void, Never>] = []
    private enum Update: Sendable { case progress(BenchmarkProgress), cleaning(Int) }

    init(store: DriveStore, engine: (any BenchmarkOperating)? = nil, worker: any MeasurementServing = SystemMeasurements(), stallTimeout: TimeInterval = 30) {
        self.store = store; self.engine = engine; self.worker = worker
        watchdog = WriteOperationWatchdog(timeout: stallTimeout)
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// True when a run is active on a drive other than the given one.
    func isBusyElsewhere(driveID: UInt64) -> Bool {
        isRunning && runningDriveID != nil && runningDriveID != driveID
    }

    func start(snapshot: DriveSnapshot, volume: VolumeUsage, config: BenchmarkConfig) {
        guard !isRunning, !store.benchmarkInProgress else { return }
        do { operationLease = try store.operations.begin(driveID: snapshot.id, kind: .benchmark) }
        catch { ownerDriveID = snapshot.id; state = .failed(error.localizedDescription); return }
        let driveKey = snapshot.identity.key
        let engine = engine
        let worker = worker, id = UUID()
        measurementID = id; isCleaning = false
        recoveredResultMessage = nil
        measurementTarget = (id, snapshot.drive, volume, DiskWorkspaceRecovery.writeDirectoryPath(for: volume), MeasurementOrigin(drive: snapshot.drive, identity: snapshot.identity))
        isCancelling = false
        measurementBegan = false
        let started = Date()
        runGeneration += 1
        let generation = runGeneration
        let cancelFlag = CancelBox()
        self.cancelFlag = cancelFlag

        samples = []
        sampleCounter = 0
        progress = nil
        lastWriteMBps = 0
        lastReadMBps = 0
        peakMBps = 0
        runningDriveID = snapshot.id
        ownerDriveID = snapshot.id
        runningVolume = volume
        state = .running(.sequentialWrite)
        isStalled = false
        armWatchdog(generation: generation, flag: cancelFlag, preparing: true)

        activeWork += 1
        task = Task { [self] in
            defer { workEnded() }
            var journalJob: MeasurementJobLease?
            do {
                let lease = try await DriveCommandLock.acquireAsync(registryEntryID: snapshot.id)
                diskLease = lease
                try await store.prepareMeasurement(snapshot.drive, lease: lease, cancelled: { cancelFlag.isSet })
                if engine == nil {
                    journalJob = try await worker.prepareJournal(.init(id: id, drive: snapshot.drive, driveKey: driveKey, volume: volume,
                        operation: .benchmark(config), origin: MeasurementOrigin(drive: snapshot.drive, identity: snapshot.identity)))
                }
                measurementBegan = true
                let publication = LatestProgress<Update> { [weak self] update in
                    guard let self, generation == self.runGeneration, self.isRunning else { return }
                    switch update { case .progress(let p): self.apply(progress: p, since: started, generation: generation); case .cleaning: self.isCleaning = true }
                }
                let result: BenchmarkResult
                if let engine {
                    // Explicit fixture injection only. Production uses the
                    // supervised child below and blocks no app I/O thread.
                    armWatchdog(generation: generation, flag: cancelFlag, preparing: false)
                    result = try await Self.runOnDedicatedThread {
                        try engine.run(
                        volume: volume, config: config,
                        isCancelled: { cancelFlag.isSet },
                        progress: { publication.submit(.progress($0)) })
                    }
                } else {
                    watchdog.stop()
                    result = try await worker.benchmark(drive: snapshot.drive, volume: volume, config: config, id: id, lease: lease, job: journalJob,
                        cancelled: { cancelFlag.isSet }, progress: { publication.submit(.progress($0)) }, cleaning: { publication.submit(.cleaning($0)) })
                }
                let record = journalJob.map { completedMeasurementRecord(job: $0, outcome: .benchmark(result)) }
                journalJob = nil // Actual child exit was awaited; release before journal GC.
                unsavedResults.append(UnsavedResult(id: id, result: result, driveKey: driveKey, record: record))
                finish(.finished(result))
                await retrySaving()
            } catch let error as BenchmarkError where error == .cancelled {
                finish(.idle)
            } catch let error as CommandError where error.reason == .cancelled {
                // The worker client turns confirmed cleanup into BenchmarkError.cancelled.
                // A remaining process error can still own an unreaped child.
                finish(.failed(error.localizedDescription), error: error)
            } catch DriveOperationError.cancelled {
                finish(.idle)
            } catch {
                if let record = recoveredMeasurementRecord(error), record.id == id, record.intent.driveKey == driveKey,
                   journalJob?.intent.nonce == record.intent.nonce, case .benchmark(let result) = record.terminal?.outcome {
                    journalJob = nil
                    unsavedResults.append(UnsavedResult(id: id, result: result, driveKey: driveKey, record: record))
                    recoveredResultMessage = error.localizedDescription
                    finish(.finished(result)); await retrySaving()
                } else { finish(.failed(error.localizedDescription), error: error) }
            }
        }
    }

    func retrySaving(reconnect: Bool = false) async {
        guard !isSaving else { return }
        let publishesHistory = reconnect || !unsavedResults.isEmpty
        isSaving = true
        defer {
            isSaving = false
            if publishesHistory {
                historyRevision = UUID()
                store.measurementRecovery.requestRefresh()
            }
            let waiters = savingWaiters; savingWaiters.removeAll(); for waiter in waiters { waiter.resume() }
        }
        do {
            if reconnect { try await store.history.connect(retry: true) }
            while let pending = unsavedResults.first {
                let result = pending.result, key = pending.driveKey
                if let record = pending.record {
                    let receipt = try await store.history.recordMeasurement(record)
                    // History is durable even if metadata GC fails. Retain a
                    // recovery warning, not a false unsaved-result assertion.
                    do { try await worker.discardJournal(receipt); journalCleanupIssues.removeValue(forKey: pending.id) }
                    catch { journalCleanupIssues[pending.id] = .init(driveKey: key, message: error.localizedDescription) }
                } else {
                    try await store.history.run("benchmark.record:" + key) { try await $0.record(benchmark: result, driveKey: key) }
                }
                unsavedResults.removeAll { $0.id == pending.id }
            }
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }

    func cancel() {
        isCancelling = isRunning
        cancelFlag?.trip()
    }
    func waitForCompletion() async {
        if activeWork > 0 { await withCheckedContinuation { workWaiters.append($0) } }
        if isSaving { await withCheckedContinuation { savingWaiters.append($0) } }
    }
    private func workEnded() {
        activeWork -= 1
        store.measurementRecovery.requestRefresh()
        if activeWork == 0 { let waiters = workWaiters; workWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
    }

    private static func runOnDedicatedThread(
        _ work: @escaping @Sendable () throws -> BenchmarkResult
    ) async throws -> BenchmarkResult {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = "com.maclife.mdrivehealth.benchmark"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Return to idle from a finished/failed state (the "Run again" button).
    func reset() {
        guard !isRunning else { return }
        state = .idle
        progress = nil
        samples = []
        lastWriteMBps = 0
        lastReadMBps = 0
        peakMBps = 0
        runningDriveID = nil
        runningVolume = nil
        ownerDriveID = nil
        measurementID = nil; isCleaning = false
    }
    func reconcileWorkspaceReviews(_ evidence: WorkspaceRecoveryEvidence) {
        workspaceReviews.removeAll { evidence.confirmsAbsence(of: $0) }
    }

    // MARK: - Private

    private func apply(progress p: BenchmarkProgress, since started: Date,
                       generation: Int) {
        guard generation == runGeneration, isRunning else { return }
        watchdog.ping()
        progress = p
        state = .running(p.phase)
        let mbps = p.instantaneousBytesPerSecond / 1e6
        switch p.phase {
        case .sequentialWrite, .randomWrite: lastWriteMBps = mbps
        case .sequentialRead, .randomRead: lastReadMBps = mbps
        }
        peakMBps = max(peakMBps, mbps)
        sampleCounter += 1
        samples.append(SpeedSample(
            id: sampleCounter, phase: p.phase,
            elapsed: Date().timeIntervalSince(started),
            megabytesPerSecond: mbps))
        // Keep the live chart light: past ~800 points, halve by dropping
        // every other sample — the curve's shape survives thinning.
        if samples.count > 800 {
            samples = samples.enumerated()
                .filter { $0.offset.isMultiple(of: 2) }
                .map(\.element)
        }
    }

    private func armWatchdog(generation: Int, flag: CancelBox, preparing: Bool) {
        watchdog.start(timeoutOverride: preparing ? 30 : nil) { [weak self] in
            guard let self, isRunning, generation == runGeneration else { return }
            isStalled = true; flag.trip()
            if let lease = operationLease { store.operations.markStalled(lease) }
        }
    }

    private func finish(_ newState: State, error: Error? = nil) {
        if measurementBegan, let error, measurementFailureNeedsWorkspaceReview(error), let (id, drive, volume, parent, origin) = measurementTarget,
           !workspaceReviews.contains(where: { $0.id == id }) {
            workspaceReviews.append(.init(id: id, drive: drive, volume: volume, message: error.localizedDescription, writeDirectoryPath: parent, origin: origin))
        }
        watchdog.stop(); isStalled = false; isCleaning = false; isCancelling = false
        if let lease = operationLease {
            if let pending = (error as? CommandError)?.pendingChild {
                store.operations.retainUntilExit(lease, pending: pending, diskLock: diskLease)
            } else { diskLease?.release(); store.operations.end(lease) }
        }
        diskLease = nil
        operationLease = nil
        runningDriveID = nil
        runningVolume = nil
        progress = nil
        task = nil
        cancelFlag = nil
        state = newState
    }
}

/// Cancellation shared with the process supervisor and injected test engines.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func trip() {
        lock.lock(); flag = true; lock.unlock()
    }

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}
