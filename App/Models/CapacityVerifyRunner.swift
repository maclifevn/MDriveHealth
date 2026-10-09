/*
 * CapacityVerifyRunner.swift — drives CapacityVerifier from the UI: one run
 * at a time, live progress, and the same SMART-poll suppression the speed
 * benchmark uses (both own the disk while running).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import MDriveHealthCore

protocol CapacityOperating: Sendable {
    func run(volume: VolumeUsage, config: CapacityVerifyConfig,
             isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping CapacityVerifier.ProgressHandler) throws -> CapacityVerifyResult
}
extension CapacityVerifier: CapacityOperating {}

@MainActor
@Observable
final class CapacityVerifyRunner {
    enum State {
        case idle
        case running(CapacityVerifyPhase)
        case finished(CapacityVerifyResult)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var progress: CapacityVerifyProgress?
    /// Drive the current/most recent run belongs to (survives finish; cleared
    /// by reset) — keeps results scoped to the right drive's tab.
    private(set) var ownerDriveID: UInt64?
    private(set) var runningVolume: VolumeUsage?

    private let store: DriveStore
    private let verifier: (any CapacityOperating)?
    private let worker: any MeasurementServing
    private var operationLease: DriveOperations.Lease?
    private var diskLease: DriveCommandLock.Lease?
    private let watchdog: WriteOperationWatchdog
    private(set) var isStalled = false
    private(set) var isCleaning = false
    private(set) var isCancelling = false
    private(set) var measurementID: UUID?
    private(set) var workspaceReviews: [MeasurementWorkspaceReview] = []
    private(set) var unsavedResults: [MeasurementJobRecord] = []
    private(set) var persistenceError: String?
    private(set) var journalCleanupIssues: [UUID: MeasurementJournalIssue] = [:]
    private(set) var recoveredResultMessage: String?
    private(set) var isSaving = false
    private var activeWork = 0
    private var workWaiters: [CheckedContinuation<Void, Never>] = []
    private var savingWaiters: [CheckedContinuation<Void, Never>] = []
    var requiresWorkspaceReview: Bool { !workspaceReviews.isEmpty }
    private var measurementTarget: (UUID, DriveInfo, VolumeUsage, String, MeasurementOrigin)?
    private var measurementBegan = false
    @ObservationIgnored private var task: Task<Void, Never>?
    private enum Update: Sendable { case progress(CapacityVerifyProgress), cleaning(Int) }
    private var cancelFlag: CancelBox?
    /// Straggler progress hops from a cancelled run must not touch the next
    /// run's state (same guard BenchmarkRunner uses).
    private var runGeneration = 0

    init(store: DriveStore, verifier: (any CapacityOperating)? = nil, worker: any MeasurementServing = SystemMeasurements(), stallTimeout: TimeInterval = 30) {
        self.store = store; self.verifier = verifier; self.worker = worker; watchdog = WriteOperationWatchdog(timeout: stallTimeout)
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func isBusyElsewhere(driveID: UInt64) -> Bool {
        isRunning && ownerDriveID != nil && ownerDriveID != driveID
    }

    func start(snapshot: DriveSnapshot, volume: VolumeUsage, config: CapacityVerifyConfig) {
        guard !isRunning, !store.benchmarkInProgress else { return }
        do { operationLease = try store.operations.begin(driveID: snapshot.id, kind: .capacity) }
        catch { ownerDriveID = snapshot.id; state = .failed(error.localizedDescription); return }
        let verifier = verifier
        let worker = worker, id = UUID()
        measurementID = id; isCleaning = false
        recoveredResultMessage = nil
        measurementTarget = (id, snapshot.drive, volume, DiskWorkspaceRecovery.writeDirectoryPath(for: volume), MeasurementOrigin(drive: snapshot.drive, identity: snapshot.identity))
        isCancelling = false
        measurementBegan = false
        let cancelFlag = CancelBox()
        self.cancelFlag = cancelFlag
        runGeneration += 1
        let generation = runGeneration

        progress = nil
        ownerDriveID = snapshot.id
        runningVolume = volume
        state = .running(.filling)
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
                if verifier == nil {
                    journalJob = try await worker.prepareJournal(.init(id: id, drive: snapshot.drive, driveKey: snapshot.identity.key, volume: volume,
                        operation: .capacity(config), origin: MeasurementOrigin(drive: snapshot.drive, identity: snapshot.identity)))
                }
                measurementBegan = true
                let publication = LatestProgress<Update> { [weak self] update in
                    guard let self, generation == self.runGeneration, self.isRunning else { return }
                    switch update { case .progress(let p): self.apply(p, generation: generation); case .cleaning: self.isCleaning = true }
                }
                let result: CapacityVerifyResult
                if let verifier {
                    armWatchdog(generation: generation, flag: cancelFlag, preparing: false)
                    result = try await Self.runOnDedicatedThread {
                        try verifier.run(
                        volume: volume, config: config,
                        isCancelled: { cancelFlag.isSet },
                        progress: { publication.submit(.progress($0)) })
                    }
                } else {
                    watchdog.stop()
                    result = try await worker.capacity(drive: snapshot.drive, volume: volume, config: config, id: id, lease: lease, job: journalJob,
                        cancelled: { cancelFlag.isSet }, progress: { publication.submit(.progress($0)) }, cleaning: { publication.submit(.cleaning($0)) })
                }
                if let job = journalJob { unsavedResults.append(completedMeasurementRecord(job: job, outcome: .capacity(result))) }
                journalJob = nil
                finish(.finished(result)); await retrySaving()
            } catch let error as BenchmarkError where error == .cancelled {
                finish(.idle)
            } catch let error as CommandError where error.reason == .cancelled {
                finish(.failed(error.localizedDescription), error: error)
            } catch DriveOperationError.cancelled {
                finish(.idle)
            } catch {
                if let record = recoveredMeasurementRecord(error), record.id == id, record.intent.driveKey == snapshot.identity.key,
                   journalJob?.intent.nonce == record.intent.nonce, case .capacity(let result) = record.terminal?.outcome {
                    journalJob = nil; unsavedResults.append(record); recoveredResultMessage = error.localizedDescription
                    finish(.finished(result)); await retrySaving()
                } else { finish(.failed(error.localizedDescription), error: error) }
            }
        }
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
    func retrySaving(reconnect: Bool = false) async {
        guard !isSaving else { return }
        let publishesRecovery = reconnect || !unsavedResults.isEmpty
        isSaving = true
        defer {
            isSaving = false
            if publishesRecovery { store.measurementRecovery.requestRefresh() }
            let waiters = savingWaiters; savingWaiters.removeAll(); for waiter in waiters { waiter.resume() }
        }
        do {
            if reconnect { try await store.history.connect(retry: true) }
            while let record = unsavedResults.first {
                let receipt = try await store.history.recordMeasurement(record)
                do { try await worker.discardJournal(receipt); journalCleanupIssues.removeValue(forKey: record.id) }
                catch { journalCleanupIssues[record.id] = .init(driveKey: record.intent.driveKey, message: error.localizedDescription) }
                unsavedResults.removeAll { $0.id == record.id }
            }
            persistenceError = nil
        } catch { persistenceError = error.localizedDescription }
    }
    func reconcileWorkspaceReviews(_ evidence: WorkspaceRecoveryEvidence) {
        workspaceReviews.removeAll { evidence.confirmsAbsence(of: $0) }
    }

    func reset() {
        guard !isRunning else { return }
        state = .idle
        progress = nil
        ownerDriveID = nil
        runningVolume = nil
        measurementID = nil; isCleaning = false
    }

    // MARK: - Private

    private func apply(_ p: CapacityVerifyProgress, generation: Int) {
        guard generation == runGeneration, isRunning else { return }
        watchdog.ping()
        progress = p
        state = .running(p.phase)
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
        runningVolume = nil
        progress = nil
        cancelFlag = nil
        state = newState
    }

    private static func runOnDedicatedThread(
        _ work: @escaping @Sendable () throws -> CapacityVerifyResult
    ) async throws -> CapacityVerifyResult {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                continuation.resume(with: Result { try work() })
            }
            thread.name = "com.maclife.mdrivehealth.capacityverify"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
