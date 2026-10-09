/* Descriptor-bound durable pending jobs/results. GPL-3.0-or-later. */
import Foundation
import Darwin

/// Blocking, bounded metadata I/O. App callers must run this off MainActor.
/// Each job's flock is delegated to its child and lasts through actual exit.
public final class MeasurementJournal: @unchecked Sendable {
    public static let maximumJobs = 1024
    public let rootURL: URL
    private let descriptor: Int32
    private let identity: WorkspaceDirectoryIdentity
    private let lock = NSLock()
    public init(rootURL: URL) throws {
        guard rootURL.isFileURL else { throw MeasurementJournalError.unsafeDirectory }
        self.rootURL = rootURL
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MeasurementJournalError.io("open root", errno) }
        do { identity = try MeasurementJournalFiles.directory(descriptor) }
        catch { close(descriptor); throw error }
    }
    public static func defaultRootURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MDriveHealth/measurement-jobs-v1", isDirectory: true)
    }
    deinit { close(descriptor) }
    private static func name(_ id: UUID) -> String { "job-" + id.uuidString }
    private static func receiptName(_ id: UUID) -> String { "receipt-" + id.uuidString + ".json" }
    private func consumption(_ id: UUID) throws -> MeasurementConsumption? {
        guard let bytes = try MeasurementJournalFiles.optional(Self.receiptName(id), at: descriptor) else { return nil }
        let value = try MeasurementJournalCoding.unwrap(MeasurementConsumption.self, bytes); try value.validate()
        guard value.id == id else { throw MeasurementJournalError.invalidRecord }; return value
    }
    private func withRoot<T>(_ work: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard try MeasurementJournalFiles.directory(descriptor) == identity,
              WorkspaceDirectoryIdentity.capture(at: rootURL) == identity else { throw MeasurementJournalError.changed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MeasurementJournalError.busy }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try work()
    }
    public func prepare(_ intent: MeasurementJobIntent) throws -> MeasurementJobLease {
        try intent.validate()
        return try withRoot {
            let names = try WorkspaceDirectory.entries(fd: descriptor, limit: Self.maximumJobs + 32)
            guard names.count < Self.maximumJobs else { throw MeasurementJournalError.budgetExceeded }
            let name = Self.name(intent.id)
            guard mkdirat(descriptor, name, 0o700) == 0 else { throw MeasurementJournalError.io("create job", errno) }
            // An interrupted/failed reservation is left visible. Never remove
            // an unknown path or reuse an existing run UUID.
            let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw MeasurementJournalError.io("open job", errno) }
            do {
                let directory = try MeasurementJournalFiles.directory(fd)
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MeasurementJournalError.busy }
                let bytes = try MeasurementJournalCoding.wrap(intent)
                try MeasurementJournalFiles.publish(bytes, name: "intent.json", at: fd)
                try MeasurementJournalFiles.synchronize(descriptor)
                let ticket = MeasurementJobTicket(version: 1, id: intent.id, nonce: intent.nonce, directory: directory, intentSHA256: MeasurementJournalCoding.hash(bytes))
                return try MeasurementJobLease(descriptor: fd, ticket: ticket)
            } catch { close(fd); throw error }
        }
    }
    public func openJob(id: UUID) throws -> MeasurementJobLease { try withRoot { try openJobLocked(name: Self.name(id)) } }
    private func openJobLocked(name: String) throws -> MeasurementJobLease {
        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw MeasurementJournalError.io("open job", errno) }
        do {
            let directory = try MeasurementJournalFiles.directory(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MeasurementJournalError.busy }
            let bytes = try MeasurementJournalFiles.read("intent.json", at: fd)
            let intent = try MeasurementJournalCoding.unwrap(MeasurementJobIntent.self, bytes); try intent.validate()
            guard name == Self.name(intent.id) else { throw MeasurementJournalError.invalidRecord }
            return try MeasurementJobLease(descriptor: fd, ticket: .init(version: 1, id: intent.id, nonce: intent.nonce, directory: directory, intentSHA256: MeasurementJournalCoding.hash(bytes)))
        } catch { close(fd); throw error }
    }
    /// No re-execution, deletion, or promotion of temporary records during scan.
    public func scan() throws -> MeasurementJournalScan {
        try withRoot {
            let names = try WorkspaceDirectory.entries(fd: descriptor, limit: Self.maximumJobs + 32).sorted()
            var jobs: [MeasurementRecoveredJob] = [], unknown: [String] = []
            let acknowledged = Set(names.compactMap { name -> UUID? in
                guard name.hasPrefix("receipt-"), name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropFirst(8).dropLast(5))), name == Self.receiptName(id) else { return nil }; return id
            })
            for name in names {
                if name.hasPrefix("receipt-") {
                    guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropFirst(8).dropLast(5))), name == Self.receiptName(id) else { unknown.append(name); continue }
                    if !names.contains(Self.name(id)) {
                        guard jobs.count < Self.maximumJobs else { throw MeasurementJournalError.budgetExceeded }
                        do { _ = try consumption(id); jobs.append(.init(name: name, state: .acknowledged, record: nil, cleanupConfirmed: true, diagnostic: nil)) }
                        catch { jobs.append(.init(name: name, state: .unverified, record: nil, cleanupConfirmed: false, diagnostic: error.localizedDescription)) }
                    }
                    continue
                }
                guard name.hasPrefix("job-"), let id = UUID(uuidString: String(name.dropFirst(4))), name == Self.name(id) else { unknown.append(name); continue }
                guard jobs.count < Self.maximumJobs else { throw MeasurementJournalError.budgetExceeded }
                do {
                    if acknowledged.contains(id), let marker = try consumption(id) {
                        let fd = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw MeasurementJournalError.changed }; defer { close(fd) }
                        try validateConsumptionDirectory(marker, fd: fd)
                        jobs.append(.init(name: name, state: .acknowledged, record: nil, cleanupConfirmed: true, diagnostic: nil)); continue
                    }
                    let lease = try openJobLocked(name: name), record = try lease.record()
                    jobs.append(.init(name: name, state: record.terminal == nil ? .interrupted : .completed, record: record,
                                      cleanupConfirmed: try lease.cleanupConfirmed(), diagnostic: nil))
                } catch MeasurementJournalError.busy {
                    // A surviving child owns its inherited descriptor even
                    // after parent death. Never label it interrupted or read
                    // its mutable terminal file while that lease is live.
                    jobs.append(.init(name: name, state: .active, record: nil, cleanupConfirmed: false, diagnostic: nil))
                } catch {
                    jobs.append(.init(name: name, state: .unverified, record: nil, cleanupConfirmed: false, diagnostic: error.localizedDescription))
                }
            }
            return .init(jobs: jobs, unknownEntries: unknown)
        }
    }
    /// Consume only after SQLite committed this exact immutable record. This
    /// reopens the job exclusively and verifies every child before unlink.
    public func discardCommitted(_ receipt: MeasurementHistoryReceipt) throws {
        try consume(receipt, omittingHistory: false)
    }
    /// An explicit no-history intent can discard a completed, cleaned record
    /// after output. It cannot forge a SQL receipt for an archive intent.
    public func discardOmitted(id: UUID, recordSHA256: String) throws {
        try consume(.init(id: id, recordSHA256: recordSHA256), omittingHistory: true)
    }
    private func consume(_ receipt: MeasurementHistoryReceipt, omittingHistory: Bool) throws {
        try withRoot {
            if let marker = try consumption(receipt.id) {
                guard marker.historySHA256 == receipt.recordSHA256, (marker.omittedHistory == true) == omittingHistory else { throw MeasurementJournalError.receiptMismatch }
                try collectAcknowledgedLocked(marker, borrowedDescriptor: nil); return
            }
            let lease = try openJobLocked(name: Self.name(receipt.id)), record = try lease.record()
            guard (record.intent.historyPolicy == .omit) == omittingHistory,
                  !omittingHistory || record.terminal != nil else { throw MeasurementJournalError.receiptMismatch }
            guard try record.recordSHA256 == receipt.recordSHA256 else { throw MeasurementJournalError.receiptMismatch }
            guard try lease.cleanupConfirmed() else { throw MeasurementJournalError.unconfirmedCleanup }
            let names = try WorkspaceDirectory.entries(fd: lease.descriptor, limit: MeasurementJournalFiles.maximumJobEntries)
            guard names.allSatisfy({ ["intent.json","terminal.json","cleanup.json"].contains($0) }) else { throw MeasurementJournalError.invalidRecord }
            // Check the full set before the first unlink. Malformed, linked,
            // replaced, unknown or nested contents are preserved.
            var files: [String: String] = [:]
            for name in names {
                let bytes = try MeasurementJournalFiles.read(name, at: lease.descriptor)
                switch name {
                case "intent.json": guard MeasurementJournalCoding.hash(bytes) == lease.ticket.intentSHA256 else { throw MeasurementJournalError.changed }
                case "terminal.json":
                    let terminal = try MeasurementJournalCoding.unwrap(MeasurementJobTerminal.self, bytes)
                    guard try MeasurementJobRecord(intent: lease.intent, terminal: terminal).recordSHA256 == receipt.recordSHA256 else { throw MeasurementJournalError.receiptMismatch }
                case "cleanup.json": try lease.validateCleanup(bytes)
                default: throw MeasurementJournalError.invalidRecord
                }
                files[name] = MeasurementJournalCoding.hash(bytes)
            }
            var directory = stat()
            guard fstatat(descriptor, Self.name(receipt.id), &directory, AT_SYMLINK_NOFOLLOW) == 0,
                  WorkspaceDirectoryIdentity(directory) == lease.ticket.directory else { throw MeasurementJournalError.changed }
            let marker = MeasurementConsumption(version: 1, id: receipt.id, nonce: lease.intent.nonce, directory: lease.ticket.directory,
                rootVolumeUUID: MountedFilesystemIdentity.capture(at: rootURL)?.volumeUUID, historySHA256: receipt.recordSHA256,
                omittedHistory: omittingHistory ? true : nil, files: files)
            try MeasurementJournalFiles.publish(MeasurementJournalCoding.wrap(marker), name: Self.receiptName(receipt.id), at: descriptor, entryLimit: Self.maximumJobs + 32)
            try collectAcknowledgedLocked(marker, borrowedDescriptor: lease.descriptor)
        }
    }
    public func collectAcknowledged(id: UUID) throws {
        try withRoot {
            guard let marker = try consumption(id) else { throw MeasurementJournalError.invalidRecord }
            try collectAcknowledgedLocked(marker, borrowedDescriptor: nil)
        }
    }
    private func validateConsumptionDirectory(_ marker: MeasurementConsumption, fd: Int32) throws {
        let actual = try MeasurementJournalFiles.directory(fd)
        let uuid = MountedFilesystemIdentity.capture(at: rootURL)?.volumeUUID
        guard marker.directory.matches(actual, allowDeviceChange: marker.rootVolumeUUID != nil && marker.rootVolumeUUID == uuid) else { throw MeasurementJournalError.changed }
    }
    private func collectAcknowledgedLocked(_ marker: MeasurementConsumption, borrowedDescriptor: Int32?) throws {
        let fd: Int32
        if let borrowedDescriptor { fd = borrowedDescriptor }
        else {
            fd = openat(descriptor, Self.name(marker.id), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                guard errno == ENOENT else { throw MeasurementJournalError.io("open acknowledged job", errno) }
                try removeConsumptionMarker(marker); return
            }
        }
        defer { if borrowedDescriptor == nil { close(fd) } }
        try validateConsumptionDirectory(marker, fd: fd)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MeasurementJournalError.busy }
        let names = try WorkspaceDirectory.entries(fd: fd, limit: MeasurementJournalFiles.maximumJobEntries)
        guard names.allSatisfy({ marker.files[$0] != nil }) else { throw MeasurementJournalError.invalidRecord }
        var identities: [String: WorkspaceFileIdentity] = [:]
        for name in names {
            let (bytes, identity) = try MeasurementJournalFiles.readOwned(name, at: fd)
            guard marker.files[name] == MeasurementJournalCoding.hash(bytes) else { throw MeasurementJournalError.changed }
            identities[name] = identity
        }
        var directory = stat()
        guard fstatat(descriptor, Self.name(marker.id), &directory, AT_SYMLINK_NOFOLLOW) == 0,
              WorkspaceDirectoryIdentity.capture(descriptor: fd) == WorkspaceDirectoryIdentity(directory) else { throw MeasurementJournalError.changed }
        for name in names {
            var info = stat()
            guard let expected = identities[name], fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  expected.matches(info), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw MeasurementJournalError.changed }
            guard unlinkat(fd, name, 0) == 0 else { throw MeasurementJournalError.io("unlink acknowledged record", errno) }
        }
        try MeasurementJournalFiles.synchronize(fd)
        guard unlinkat(descriptor, Self.name(marker.id), AT_REMOVEDIR) == 0 else { throw MeasurementJournalError.io("remove acknowledged job", errno) }
        try MeasurementJournalFiles.synchronize(descriptor)
        try removeConsumptionMarker(marker)
    }
    private func removeConsumptionMarker(_ marker: MeasurementConsumption) throws {
        let name = Self.receiptName(marker.id), (bytes, identity) = try MeasurementJournalFiles.readOwned(name, at: descriptor)
        let current = try MeasurementJournalCoding.unwrap(MeasurementConsumption.self, bytes); try current.validate()
        guard current.id == marker.id, current.nonce == marker.nonce, current.historySHA256 == marker.historySHA256,
              current.directory == marker.directory, current.files == marker.files, current.rootVolumeUUID == marker.rootVolumeUUID,
              current.omittedHistory == marker.omittedHistory else { throw MeasurementJournalError.changed }
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0, identity.matches(info), info.st_nlink == 1 else { throw MeasurementJournalError.changed }
        guard unlinkat(descriptor, name, 0) == 0 else { throw MeasurementJournalError.io("remove consumption receipt", errno) }
        try MeasurementJournalFiles.synchronize(descriptor)
    }

}
public final class MeasurementJobLease: @unchecked Sendable {
    public let intent: MeasurementJobIntent
    public let ticket: MeasurementJobTicket
    let descriptor: Int32
    private let lock = NSLock()
    private var lastReadRecord: MeasurementJobRecord?
    init(descriptor: Int32, ticket: MeasurementJobTicket) throws {
        try ticket.validate()
        guard try MeasurementJournalFiles.directory(descriptor) == ticket.directory else { throw MeasurementJournalError.changed }
        let bytes = try MeasurementJournalFiles.read("intent.json", at: descriptor)
        let intent = try MeasurementJournalCoding.unwrap(MeasurementJobIntent.self, bytes); try intent.validate()
        guard intent.id == ticket.id, intent.nonce == ticket.nonce, MeasurementJournalCoding.hash(bytes) == ticket.intentSHA256 else { throw MeasurementJournalError.invalidRecord }
        self.descriptor = descriptor; self.ticket = ticket; self.intent = intent
    }
    deinit { close(descriptor) }
    public func delegatedFD() throws -> Int32 {
        guard try MeasurementJournalFiles.directory(descriptor) == ticket.directory else { throw MeasurementJournalError.changed }
        return descriptor // BoundedProcess duplicates this into the child.
    }
    public static func adopting(descriptor inherited: Int32, ticket: MeasurementJobTicket) throws -> MeasurementJobLease {
        let fd = fcntl(inherited, F_DUPFD_CLOEXEC, 6)
        guard fd >= 0 else { throw MeasurementJournalError.io("duplicate delegated job", errno) }
        let lease: MeasurementJobLease
        do { lease = try MeasurementJobLease(descriptor: fd, ticket: ticket) }
        catch { close(fd); throw error }
        let independent = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard independent >= 0 else { throw MeasurementJournalError.io("verify delegated job lock", errno) }
        defer { close(independent) }
        if flock(independent, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(independent, LOCK_UN)
            throw MeasurementJournalError.unsafeDirectory
        }
        guard errno == EWOULDBLOCK else { throw MeasurementJournalError.io("verify job ownership", errno) }
        // Another OFD holding a lock is not evidence that the delegated OFD
        // owns it. Reentrant flock succeeds only for the actual inherited OFD
        // while the independent descriptor remains excluded.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw MeasurementJournalError.unsafeDirectory }
        return lease // lease owns fd on every post-initialization path.
    }

    public func validate(request: MeasurementRequest) throws {
        guard intent.origin != nil, request.job == ticket, request.id == intent.id, request.drive == intent.drive, request.volume == intent.volume,
              try MeasurementJournalCoding.encode(request.operation) == MeasurementJournalCoding.encode(intent.operation),
              intent.writeDirectoryPath == DiskWorkspaceRecovery.writeDirectoryPath(for: request.volume) else { throw MeasurementJournalError.invalidRecord }
    }
    public func record() throws -> MeasurementJobRecord {
        lock.lock(); defer { lock.unlock() }
        let terminal = try MeasurementJournalFiles.optional("terminal.json", at: descriptor).map { try MeasurementJournalCoding.unwrap(MeasurementJobTerminal.self, $0) }
        let record = MeasurementJobRecord(intent: intent, terminal: terminal); try record.validate(); lastReadRecord = record; return record
    }
    /// The client has already validated this after actual child exit. App
    /// publication needs no second filesystem read to preserve that result.
    public func cachedRecord() -> MeasurementJobRecord? {
        lock.lock(); defer { lock.unlock() }; return lastReadRecord
    }
    public func writeTerminal(_ terminal: MeasurementJobTerminal) throws {
        lock.lock(); defer { lock.unlock() }
        try terminal.validate(intent: intent)
        let bytes = try MeasurementJournalCoding.wrap(terminal)
        if let stored = try MeasurementJournalFiles.optional("terminal.json", at: descriptor) {
            guard stored == bytes else { throw MeasurementJournalError.changed }
            try MeasurementJournalFiles.synchronize(descriptor); return
        }
        try MeasurementJournalFiles.publish(bytes, name: "terminal.json", at: descriptor)
    }
    /// If killed between fsync and exclusive rename, an intact single staged
    /// terminal can be explicitly promoted. Torn/conflicting records stay put.
    public func recoverStagedTerminal() throws {
        lock.lock(); defer { lock.unlock() }
        if try MeasurementJournalFiles.optional("terminal.json", at: descriptor) != nil { return }
        let names = try WorkspaceDirectory.entries(fd: descriptor, limit: MeasurementJournalFiles.maximumJobEntries).filter { $0.hasPrefix(".write-") }
        guard names.count == 1, let name = names.first else { if names.isEmpty { return }; throw MeasurementJournalError.invalidRecord }
        let bytes = try MeasurementJournalFiles.read(name, at: descriptor)
        let terminal = try MeasurementJournalCoding.unwrap(MeasurementJobTerminal.self, bytes); try terminal.validate(intent: intent)
        guard renameatx_np(descriptor, name, descriptor, "terminal.json", UInt32(RENAME_EXCL)) == 0 else { throw MeasurementJournalError.io("recover staged terminal", errno) }
        try MeasurementJournalFiles.synchronize(descriptor)
    }
    public func cleanupConfirmed() throws -> Bool {
        if try record().terminal?.outcome.cleanupConfirmed == true { return true }
        guard let bytes = try MeasurementJournalFiles.optional("cleanup.json", at: descriptor) else { return false }
        try validateCleanup(bytes); return true
    }
    func validateCleanup(_ bytes: Data) throws {
        let proof = try MeasurementJournalCoding.unwrap(Cleanup.self, bytes)
        guard proof.id == intent.id, proof.nonce == intent.nonce else { throw MeasurementJournalError.invalidRecord }
    }
    private struct Cleanup: Codable { let id: UUID; let nonce: UUID }
    public func confirmCleanup(currentOrigin: MeasurementOrigin, currentVolume: VolumeUsage, scan: DiskWorkspaceScan) throws {
        guard intent.origin?.matches(currentOrigin) == true,
              let oldMount = intent.volume.mountIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)),
              let oldWrite = intent.volume.writeIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)),
              oldMount == currentVolume.mountIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)),
              oldWrite == currentVolume.writeIdentity?.volumeUUID.flatMap(UUID.init(uuidString:)),
              (intent.volume.mountPoint == "/") == (currentVolume.mountPoint == "/"),
              intent.volume.mountPoint != "/" || intent.writeDirectoryPath == DiskWorkspaceRecovery.writeDirectoryPath(for: currentVolume),
              let original = intent.volume.writeDirectoryIdentity, let current = currentVolume.writeDirectoryIdentity,
              original.matches(current, allowDeviceChange: true), scan.complete,
              !scan.leftovers.contains(where: { $0.status == .unverified || DiskWorkspaceRecovery.sessionID(forName: $0.name) == intent.id }) else { throw MeasurementJournalError.unconfirmedCleanup }
        try scan.validate(parentPath: DiskWorkspaceRecovery.writeDirectoryPath(for: currentVolume), expectedParentIdentity: current)
        lock.lock(); defer { lock.unlock() }
        let bytes = try MeasurementJournalCoding.wrap(Cleanup(id: intent.id, nonce: intent.nonce))
        if let stored = try MeasurementJournalFiles.optional("cleanup.json", at: descriptor) { guard stored == bytes else { throw MeasurementJournalError.changed }; return }
        try MeasurementJournalFiles.publish(bytes, name: "cleanup.json", at: descriptor)
    }
}
// Only private, regular, one-link records on the job directory's device. These
// helpers never follow a file link or recurse into user-controlled contents.
enum MeasurementJournalFiles {
    static let maximumJobEntries = 8
    static func directory(_ fd: Int32) throws -> WorkspaceDirectoryIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
              let identity = WorkspaceDirectoryIdentity.capture(descriptor: fd) else { throw MeasurementJournalError.unsafeDirectory }; return identity
    }
    static func optional(_ name: String, at fd: Int32) throws -> Data? {
        var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw MeasurementJournalError.io("inspect record", errno)
        }
        return try read(name, at: fd)
    }
    static func read(_ name: String, at directoryFD: Int32) throws -> Data { try readOwned(name, at: directoryFD).0 }
    static func readOwned(_ name: String, at directoryFD: Int32) throws -> (Data, WorkspaceFileIdentity) {
        let file = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw MeasurementJournalError.io("open record", errno) }; defer { close(file) }
        var info = stat(), parent = stat()
        guard fstat(file, &info) == 0, fstat(directoryFD, &parent) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_dev == parent.st_dev, info.st_size > 0, info.st_size <= MeasurementJournalCoding.recordLimit + 1 else { throw MeasurementJournalError.invalidRecord }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = Darwin.read(file, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw MeasurementJournalError.io("read record", errno) }; if n == 0 { break }
            guard data.count + n <= MeasurementJournalCoding.recordLimit + 1 else { throw MeasurementJournalError.budgetExceeded }; data.append(contentsOf: buffer.prefix(n))
        }
        guard data.count == info.st_size else { throw MeasurementJournalError.invalidRecord }; return (data, WorkspaceFileIdentity(info))
    }
    static func synchronize(_ fd: Int32) throws { guard fsync(fd) == 0 else { throw MeasurementJournalError.io("fsync", errno) } }
    static func publish(_ bytes: Data, name: String, at fd: Int32, entryLimit: Int = maximumJobEntries) throws {
        guard bytes.count <= MeasurementJournalCoding.recordLimit + 1 else { throw MeasurementJournalError.budgetExceeded }
        let entries = try WorkspaceDirectory.entries(fd: fd, limit: entryLimit)
        guard entries.count < entryLimit else { throw MeasurementJournalError.budgetExceeded }
        let temporary = ".write-\(UUID().uuidString).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw MeasurementJournalError.io("reserve record", errno) }; defer { close(file) }
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(file, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw MeasurementJournalError.io("write record", n == 0 ? EIO : errno) }; offset += n
        }
        try synchronize(file)
        guard renameatx_np(fd, temporary, fd, name, UInt32(RENAME_EXCL)) == 0 else { throw MeasurementJournalError.io("publish record", errno) }
        try synchronize(fd)
    }
}
