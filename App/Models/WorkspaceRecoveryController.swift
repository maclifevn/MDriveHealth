/* App recovery catalog; supervised metadata scan and explicit proof-bound cleanup. GPL-3.0-or-later. */
import Foundation
import Observation
import MDriveHealthCore

struct WorkspaceRecoveryTarget: Sendable, Identifiable {
    let drive: DriveInfo
    let volume: VolumeUsage
    let identity: DriveIdentity
    var parentPath: String { DiskWorkspaceRecovery.writeDirectoryPath(for: volume) }
    private var selectedUUID: UUID? { volume.mountIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)) }
    private var writeUUID: UUID? { volume.writeIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)) }
    var hasStableIdentity: Bool { selectedUUID != nil && writeUUID != nil && volume.writeDirectoryIdentity?.isValid == true }
    var id: String {
        guard let selectedUUID, let writeUUID else { return "unidentified:\(drive.id):\(volume.bsdName):\(volume.mountPoint)" }
        // External scans cover the mounted root even when its name changes.
        // A boot scan covers this process's current temporary directory only.
        return selectedUUID.uuidString + ":" + writeUUID.uuidString + ":" + (volume.mountPoint == "/" ? parentPath : "root")
    }
    func sameAttachment(as other: Self) -> Bool {
        drive == other.drive && identity == other.identity && volume.bsdName == other.volume.bsdName && volume.mountPoint == other.volume.mountPoint
            && volume.mountIdentity == other.volume.mountIdentity && volume.writeIdentity == other.volume.writeIdentity
            && volume.writeDirectoryIdentity == other.volume.writeDirectoryIdentity && parentPath == other.parentPath
    }
    fileprivate func matches(_ review: MeasurementWorkspaceReview) -> Bool {
        guard hasStableIdentity, review.origin.matches(MeasurementOrigin(drive: drive, identity: identity)),
              selectedUUID == review.volume.mountIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)),
              writeUUID == review.volume.writeIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)),
              (volume.mountPoint == "/") == (review.volume.mountPoint == "/"),
              let originalParent = review.volume.writeDirectoryIdentity,
              let currentParent = volume.writeDirectoryIdentity,
              originalParent.matches(currentParent, allowDeviceChange: true) else { return false }
        return volume.mountPoint != "/" || parentPath == review.writeDirectoryPath
    }
}
struct WorkspaceRecoveryEvidence: Sendable {
    fileprivate let target: WorkspaceRecoveryTarget
    fileprivate let scan: DiskWorkspaceScan
    func confirmsAbsence(of review: MeasurementWorkspaceReview) -> Bool {
        // Unknown candidates might contain a renamed/damaged session. A
        // partial/unavailable scan can never clear a review.
        scan.complete && target.matches(review) && !scan.leftovers.contains {
            $0.status == .unverified || DiskWorkspaceRecovery.sessionID(forName: $0.name) == review.id
        }
    }
    func proofConfirmingAbsence(of review: MeasurementWorkspaceReview) -> WorkspaceRecoveryProof? {
        guard confirmsAbsence(of: review) else { return nil }
        return .init(origin: MeasurementOrigin(drive: target.drive, identity: target.identity), volume: target.volume, scan: scan)
    }
}
struct WorkspaceRecoveryProof: Sendable {
    let origin: MeasurementOrigin
    let volume: VolumeUsage
    let scan: DiskWorkspaceScan
}
struct WorkspaceRecoveryVolume: Identifiable {
    enum State { case pending, scanning, cleaning, ready, deferred, unavailable }
    var id: String { target.id }
    var target: WorkspaceRecoveryTarget
    var version = UUID()
    var scanID = UUID()
    var attached = true
    var ambiguous = false
    var state: State = .pending
    var scan: DiskWorkspaceScan?
    var isCurrent = false
    var lastScanned: Date?
    var error: String?

    var displayError: String? {
        guard let error else { return nil }
        if error == WorkspaceRecoveryError.budgetExceeded.localizedDescription {
            return String(localized: "recovery.scanBudgetExceeded.help",
                defaultValue: "Kiểm tra file tạm đã dừng vì vượt giới hạn quét. Chưa thể xác nhận có file đo còn sót hay không.")
        }
        return error
    }
}
struct WorkspaceCleanupSelection: Identifiable {
    let id = UUID()
    let recordID: String
    let version: UUID
    let scanID: UUID
    let target: WorkspaceRecoveryTarget
    let leftover: DiskWorkspaceLeftover
}

@MainActor @Observable final class WorkspaceRecoveryController {
    static let maximumAttachedTargets = 256
    static let maximumRecords = 1024
    private(set) var records: [WorkspaceRecoveryVolume] = []
    private(set) var catalogIssue: String?
    @ObservationIgnored var onCompleteScan: ((WorkspaceRecoveryEvidence) -> Void)?
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var currentTasks: [String: UUID] = [:]
    private let operations: DriveOperations
    private let hardware: any DriveHardwareServing
    private var suspended = false
    init(operations: DriveOperations, hardware: any DriveHardwareServing) { self.operations = operations; self.hardware = hardware }
    var isBusy: Bool { !tasks.isEmpty }
    var hasAttention: Bool {
        catalogIssue != nil || records.contains { !($0.scan?.leftovers.isEmpty ?? true) || $0.error != nil || $0.scan?.complete == false || $0.state == .deferred }
    }
    /// A scan error alone does not establish that test files were found.
    /// Retain known candidates even when their last scan is stale/offline.
    var hasFilesToReview: Bool {
        records.contains { !($0.scan?.leftovers.isEmpty ?? true) }
    }

    /// Called after fleet resolution. No automatic deletion. Read errors and
    /// disconnected volumes retain their prior catalog as explicitly stale.
    func updateFleet(_ fleet: [DriveSnapshot]) {
        guard !suspended, !operations.isShuttingDown else { return }
        let targets = fleet.flatMap { snapshot in snapshot.volumes.map { (WorkspaceRecoveryTarget(drive: snapshot.drive, volume: $0, identity: snapshot.identity), snapshot.skippedWhileSleeping || snapshot.isStale) } }
        let grouped = Dictionary(grouping: targets, by: { $0.0.id })
        let keys = grouped.keys.sorted()
        catalogIssue = keys.count > Self.maximumAttachedTargets ? String(localized: "recovery.catalogLimit", defaultValue: "Danh sách volume vượt giới hạn; kiểm tra chưa đầy đủ.") : nil
        let attached = Set(keys.prefix(Self.maximumAttachedTargets))
        for index in records.indices where !attached.contains(records[index].id) {
            if records[index].attached { invalidate(index) }
            records[index].attached = false
        }
        var scanKeys: [String] = []
        for key in attached.sorted() {
            guard let values = grouped[key], let (target, deferred) = values.first else { continue }
            let ambiguous = values.count != 1
            let index: Int
            var changed = false
            if let existing = records.firstIndex(where: { $0.id == key }) {
                index = existing
                changed = !records[index].attached || !records[index].target.sameAttachment(as: target) || records[index].ambiguous != ambiguous
                if changed { invalidate(index) }
                records[index].target = target; records[index].attached = true
            } else {
                guard records.count < Self.maximumRecords else {
                    catalogIssue = String(localized: "recovery.catalogLimit", defaultValue: "Danh sách volume vượt giới hạn; kiểm tra chưa đầy đủ."); continue
                }
                index = records.count; records.append(.init(target: target)); changed = true
            }
            records[index].ambiguous = ambiguous
            if ambiguous || !target.hasStableIdentity {
                records[index].state = .unavailable; records[index].isCurrent = false
                records[index].error = String(localized: "recovery.identityUnavailable", defaultValue: "Volume chưa có định danh duy nhất; không thể xác minh hoặc dọn workspace.")
            } else if deferred {
                if changed || records[index].scan == nil {
                    records[index].state = .deferred; records[index].isCurrent = false
                    records[index].error = String(localized: "recovery.deferred", defaultValue: "Chưa quét: ổ ngủ hoặc thông tin hiện tại chưa đủ. Có thể yêu cầu quét lại khi ổ sẵn sàng.")
                }
            } else if changed { scanKeys.append(key) }
        }
        for key in scanKeys { requestScan(key) }
    }
    private func invalidate(_ index: Int) {
        if let token = currentTasks.removeValue(forKey: records[index].id) { tasks[token]?.cancel() }
        records[index].version = UUID(); records[index].scanID = UUID(); records[index].isCurrent = false
        records[index].state = .pending
    }
    func requestScanAll() {
        for key in records.filter({ $0.attached && !$0.ambiguous && $0.target.hasStableIdentity }).map(\.id) { requestScan(key) }
    }
    func requestScan(_ key: String) {
        guard !suspended, !operations.isShuttingDown, currentTasks[key] == nil,
              let record = records.first(where: { $0.id == key }), record.attached, !record.ambiguous, record.target.hasStableIdentity else { return }
        startTask(key: key) { await self.scan(key: key, version: record.version) }
    }
    private func startTask(key: String, work: @escaping @MainActor () async -> Void) {
        let token = UUID(); currentTasks[key] = token
        tasks[token] = Task { [self] in
            defer { tasks.removeValue(forKey: token); if currentTasks[key] == token { currentTasks.removeValue(forKey: key) } }
            await work()
        }
    }
    private func index(key: String, version: UUID) -> Int? {
        records.firstIndex { $0.id == key && $0.version == version && $0.attached && !$0.ambiguous }
    }
    private func scan(key: String, version: UUID) async {
        guard let index = index(key: key, version: version) else { return }
        let target = records[index].target
        records[index].state = .scanning; records[index].isCurrent = false; records[index].error = nil
        records[index].scanID = UUID()
        var operation: DriveOperations.Lease?
        do {
            let lease = try await operations.beginRead(driveID: target.drive.id, kind: .workspaceScan); operation = lease
            try Task.checkCancellation()
            let result = try await hardware.workspaces(target.drive, volume: target.volume)
            try Task.checkCancellation(); try result.validate(parentPath: target.parentPath, expectedParentIdentity: target.volume.writeDirectoryIdentity)
            operations.end(lease); operation = nil
            guard let index = self.index(key: key, version: version), !suspended else { return }
            records[index].scan = result; records[index].state = .ready; records[index].isCurrent = true
            records[index].lastScanned = Date(); records[index].error = result.diagnostic
            if result.complete { onCompleteScan?(.init(target: target, scan: result)) }
        } catch {
            if let operation { operations.fail(operation, error: error) }
            if let index = self.index(key: key, version: version) {
                records[index].state = .unavailable; records[index].isCurrent = false; records[index].error = error.localizedDescription
            }
        }
    }
    func selection(recordID: String, name: String) -> WorkspaceCleanupSelection? {
        guard let record = records.first(where: { $0.id == recordID }), record.attached, !record.ambiguous, record.isCurrent,
              currentTasks[recordID] == nil, record.state == .ready,
              operations.canBegin(driveID: record.target.drive.id, kind: .workspaceCleanup),
              let leftover = record.scan?.leftovers.first(where: { $0.name == name && $0.status == .recoverable && $0.proof != nil }) else { return nil }
        return .init(recordID: recordID, version: record.version, scanID: record.scanID, target: record.target, leftover: leftover)
    }
    func isCurrent(_ selection: WorkspaceCleanupSelection) -> Bool {
        guard !suspended, !operations.isShuttingDown,
              let current = self.selection(recordID: selection.recordID, name: selection.leftover.name) else { return false }
        return current.version == selection.version && current.scanID == selection.scanID && current.leftover == selection.leftover
            && current.target.sameAttachment(as: selection.target)
    }
    /// Called only by the explicit confirmation action. The helper rechecks
    /// attachment, delegated lock, manifest proof and every inode before unlink.
    func cleanup(_ selection: WorkspaceCleanupSelection) async {
        guard isCurrent(selection) else { return }
        let key = selection.recordID
        startTask(key: key) { await self.performCleanup(selection) }
        if let token = currentTasks[key], let task = tasks[token] { await task.value }
    }
    private func performCleanup(_ selection: WorkspaceCleanupSelection) async {
        let key = selection.recordID, version = selection.version, target = selection.target
        guard let index = index(key: key, version: version) else { return }
        records[index].state = .cleaning; records[index].isCurrent = false; records[index].error = nil
        var operation: DriveOperations.Lease?
        var disk: DriveCommandLock.Lease?
        do {
            let lease = try operations.begin(driveID: target.drive.id, kind: .workspaceCleanup); operation = lease
            let lock = try await DriveCommandLock.acquireAsync(registryEntryID: target.drive.id); disk = lock
            try Task.checkCancellation()
            guard self.index(key: key, version: version) != nil else { throw WorkspaceRecoveryError.changed }
            try await hardware.cleanupWorkspace(target.drive, volume: target.volume, leftover: selection.leftover, lease: lock)
            try Task.checkCancellation()
            lock.release(); disk = nil; operations.end(lease); operation = nil
            await scan(key: key, version: version)
        } catch {
            if let operation, let pending = (error as? CommandError)?.pendingChild {
                operations.retainUntilExit(operation, pending: pending, diskLock: disk); disk = nil
            } else { disk?.release(); if let operation { operations.end(operation) } }
            if let index = self.index(key: key, version: version) {
                records[index].state = .unavailable; records[index].error = error.localizedDescription; records[index].isCurrent = false
            }
        }
    }
    func beginShutdown() { suspended = true; for task in tasks.values { task.cancel() } }
    func waitForCompletion() async { while !tasks.isEmpty { for task in Array(tasks.values) { await task.value } } }
    func resumeAfterShutdown() { suspended = false }
}
