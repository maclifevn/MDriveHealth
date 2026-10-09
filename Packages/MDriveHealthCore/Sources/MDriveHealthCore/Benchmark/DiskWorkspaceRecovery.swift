/* Inspect/recover proven-owned measurement leftovers. GPL-3.0-or-later. */
import Foundation
import Darwin
import CryptoKit

public struct DiskWorkspaceLeftover: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case recoverable, unverified }
    public var id: String { name }
    public let name: String
    public let path: String
    public let status: Status
    public let bytes: UInt64?
    public let fileCount: Int?
    public let diagnostic: String?
    /// Binds an explicit cleanup to the exact manifest and directory inspected.
    public let proof: String?
}
public struct DiskWorkspaceScan: Codable, Sendable {
    public let leftovers: [DiskWorkspaceLeftover]
    public let complete: Bool
    public let diagnostic: String?
    public let parentIdentity: WorkspaceDirectoryIdentity?
    public init(leftovers: [DiskWorkspaceLeftover], complete: Bool, diagnostic: String?, parentIdentity: WorkspaceDirectoryIdentity? = nil) {
        self.leftovers = leftovers; self.complete = complete; self.diagnostic = diagnostic; self.parentIdentity = parentIdentity
    }
    public func validate(parentPath: String? = nil, expectedParentIdentity: WorkspaceDirectoryIdentity? = nil) throws {
        guard leftovers.count <= DiskWorkspaceRecovery.maximumWorkspaces,
              parentIdentity.map(\.isValid) ?? true,
              expectedParentIdentity.map({ $0.isValid && $0 == parentIdentity }) ?? true,
              Set(leftovers.map(\.name)).count == leftovers.count,
              diagnostic.map({ !$0.isEmpty && $0.utf8.count <= 2048 }) ?? complete,
              leftovers.allSatisfy({ entry in
                  !entry.name.isEmpty && entry.name.utf8.count <= 255 && !entry.name.contains("/") && !entry.name.utf8.contains(0)
                      && entry.path.hasPrefix("/") && entry.path.utf8.count <= 4096 && !entry.path.utf8.contains(0)
                      && (entry.diagnostic.map { $0.utf8.count <= 2048 } ?? true)
                      && (entry.status == .unverified ? entry.proof == nil && entry.bytes == nil && entry.fileCount == nil && entry.diagnostic != nil
                          : DiskWorkspaceRecovery.sessionID(forName: entry.name).map { DiskWorkspaceRecovery.workspaceName(for: $0) == entry.name } == true
                            && entry.diagnostic == nil && entry.bytes != nil && entry.fileCount.map { (0...DiskWorkspaceRecovery.maximumFiles).contains($0) } == true
                            && entry.proof.map { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } } == true)
              }), parentPath.map({ parent in leftovers.allSatisfy { $0.path == URL(fileURLWithPath: parent).appendingPathComponent($0.name).path } }) ?? true
        else { throw HardwareWorkerError.protocolViolation }
    }
}
public enum WorkspaceRecoveryError: Error, LocalizedError {
    case unsafe(String), budgetExceeded, changed, busy, io(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .unsafe(let reason): return "Ownership not verified: " + reason
        case .budgetExceeded: return "Workspace scan exceeded its bounded file or manifest budget"
        case .changed: return "Workspace changed since inspection; refresh before cleanup"
        case .busy: return "The volume is in use by a measurement or another recovery"
        case .io(let operation, let code): return "\(operation): \(String(cString: strerror(code))) (\(code))"
        }
    }
}

enum WorkspaceDirectory {
    static func entries(fd: Int32, limit: Int) throws -> [String] {
        let duplicate = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard duplicate >= 0 else { throw WorkspaceRecoveryError.io("open directory for scan", errno) }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw WorkspaceRecoveryError.io("fdopendir", errno) }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw WorkspaceRecoveryError.io("readdir", errno) }
                return result
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw WorkspaceRecoveryError.unsafe("invalid directory entry encoding") }
            if name == "." || name == ".." { continue }
            guard result.count < limit else { throw WorkspaceRecoveryError.budgetExceeded }
            result.append(name)
        }
    }
}

public enum DiskWorkspaceRecovery {
    public static let maximumFiles = WorkspaceJournal.maxFiles
    public static let maximumWorkspaces = 256
    static let maximumParentEntries = 20_000
    /// Pure location metadata. Does not inspect the filesystem or grant access.
    public static func writeDirectoryPath(for volume: VolumeUsage) -> String { BenchmarkLocation.writeDirectory(for: volume).path }
    public static func workspaceName(for id: UUID) -> String { WorkspaceJournal.prefix + id.uuidString }
    /// Accepts alternate UUID casing for conservative absence checks. Cleanup
    /// still requires the canonical name and manifest identities.
    public static func sessionID(forName name: String) -> UUID? {
        guard name.hasPrefix(WorkspaceJournal.prefix) else { return nil }
        return UUID(uuidString: String(name.dropFirst(WorkspaceJournal.prefix.count)))
    }

    /// Blocking filesystem I/O. App callers must use a supervised worker.
    public static func scan(volume: VolumeUsage) throws -> DiskWorkspaceScan {
        let location = try DiskTestWorkspace.validatedLocation(volume: volume)
        return try scan(parent: location.parent, filesystem: location.identity, expectedParent: location.directoryIdentity, lockAt: location.lockAt)
    }
    /// Explicit cleanup only. Scan results are never an instruction to delete
    /// directories automatically, and every inode is checked again here.
    public static func cleanup(volume: VolumeUsage, leftover: DiskWorkspaceLeftover) throws {
        let location = try DiskTestWorkspace.validatedLocation(volume: volume)
        try cleanup(parent: location.parent, filesystem: location.identity, expectedParent: location.directoryIdentity, lockAt: location.lockAt, leftover: leftover)
    }
    static func scanFixture(at parent: URL) throws -> DiskWorkspaceScan {
        guard let identity = MountedFilesystemIdentity.capture(at: parent), let directory = WorkspaceDirectoryIdentity.capture(at: parent) else { throw WorkspaceRecoveryError.changed }
        return try scan(parent: parent, filesystem: identity, expectedParent: directory, lockAt: parent)
    }
    static func cleanupFixture(at parent: URL, leftover: DiskWorkspaceLeftover) throws {
        guard let identity = MountedFilesystemIdentity.capture(at: parent), let directory = WorkspaceDirectoryIdentity.capture(at: parent) else { throw WorkspaceRecoveryError.changed }
        try cleanup(parent: parent, filesystem: identity, expectedParent: directory, lockAt: parent, leftover: leftover)
    }

    private static func withParent<T>(parent: URL, filesystem: MountedFilesystemIdentity, expectedParent: WorkspaceDirectoryIdentity, lockAt: URL,
                                      _ body: (Int32) throws -> T) throws -> T {
        let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw WorkspaceRecoveryError.io("open workspace parent", errno) }
        defer { close(parentFD) }
        let lockFD = open(lockAt.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard lockFD >= 0 else { throw WorkspaceRecoveryError.io("open recovery lock", errno) }
        defer { close(lockFD) }
        var parentInfo = statfs(), lockInfo = statfs()
        guard fstatfs(parentFD, &parentInfo) == 0, fstatfs(lockFD, &lockInfo) == 0,
              filesystem.matches(parentInfo), filesystem.matches(lockInfo),
              WorkspaceDirectoryIdentity.capture(descriptor: parentFD) == expectedParent,
              lockAt.path != parent.path || WorkspaceDirectoryIdentity.capture(descriptor: lockFD) == expectedParent,
              MountedFilesystemIdentity.capture(at: parent) == filesystem else { throw WorkspaceRecoveryError.changed }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw WorkspaceRecoveryError.busy }
            throw WorkspaceRecoveryError.io("lock workspace recovery", errno)
        }
        return try body(parentFD)
    }

    private static func scan(parent: URL, filesystem: MountedFilesystemIdentity, expectedParent: WorkspaceDirectoryIdentity, lockAt: URL) throws -> DiskWorkspaceScan {
        try withParent(parent: parent, filesystem: filesystem, expectedParent: expectedParent, lockAt: lockAt) { parentFD in
            var leftovers: [DiskWorkspaceLeftover] = []
            // An incomplete listing is an error, never a clean volume.
            let names = try WorkspaceDirectory.entries(fd: parentFD, limit: maximumParentEntries)
                .filter { $0.hasPrefix(WorkspaceJournal.prefix) || $0 == CapacityVerifier.testDirectoryName || $0 == BenchmarkLocation.testFileName }.sorted()
            for name in names.prefix(maximumWorkspaces) {
                let path = parent.appendingPathComponent(name).path
                do {
                    let inspected = try inspect(parentFD: parentFD, name: name, filesystem: filesystem)
                    close(inspected.descriptor)
                    leftovers.append(.init(name: name, path: path, status: .recoverable, bytes: inspected.bytes,
                                           fileCount: inspected.files.count, diagnostic: nil, proof: inspected.proof))
                } catch {
                    leftovers.append(.init(name: name, path: path, status: .unverified, bytes: nil,
                                           fileCount: nil, diagnostic: String(decoding: Data(error.localizedDescription.utf8.prefix(2045)), as: UTF8.self), proof: nil))
                }
            }
            return .init(leftovers: leftovers, complete: names.count <= maximumWorkspaces,
                         diagnostic: names.count > maximumWorkspaces ? "More than \(maximumWorkspaces) workspace candidates; scan is incomplete" : nil,
                         parentIdentity: expectedParent)
        }
    }

    private struct Inspection {
        let descriptor: Int32
        let header: WorkspaceHeader
        let files: [String: WorkspaceFileIdentity]
        let bytes: UInt64
        let proof: String
        let allowDeviceChange: Bool
    }
    private static func inspect(parentFD: Int32, name: String, filesystem: MountedFilesystemIdentity) throws -> Inspection {
        guard name.hasPrefix(WorkspaceJournal.prefix),
              let id = UUID(uuidString: String(name.dropFirst(WorkspaceJournal.prefix.count))),
              name == WorkspaceJournal.prefix + id.uuidString else { throw WorkspaceRecoveryError.unsafe("invalid workspace name") }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw WorkspaceRecoveryError.io("open workspace", errno) }
        do {
            var directory = stat(), fs = statfs()
            guard fstat(fd, &directory) == 0, fstatfs(fd, &fs) == 0, filesystem.matches(fs),
                  directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700,
                  WorkspaceFileIdentity(directory).valid else { throw WorkspaceRecoveryError.unsafe("directory identity or permissions") }
            let manifestFD = openat(fd, WorkspaceJournal.filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard manifestFD >= 0 else { throw WorkspaceRecoveryError.unsafe("ownership manifest is missing or unreadable") }
            let data: Data
            var manifest = stat()
            do {
                guard fstat(manifestFD, &manifest) == 0,
                      manifest.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), manifest.st_nlink == 1,
                      manifest.st_uid == geteuid(), manifest.st_dev == directory.st_dev,
                      manifest.st_mode & 0o777 == 0o600, manifest.st_size > 0,
                      manifest.st_size <= WorkspaceJournal.maxBytes else { throw WorkspaceRecoveryError.unsafe("manifest type, permissions or size") }
                var buffer = [UInt8](repeating: 0, count: 16_384), bytes = Data()
                while true {
                    let n = read(manifestFD, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n >= 0 else { throw WorkspaceRecoveryError.io("read ownership manifest", errno) }
                    if n == 0 { break }
                    guard bytes.count + n <= WorkspaceJournal.maxBytes else { throw WorkspaceRecoveryError.budgetExceeded }
                    bytes.append(contentsOf: buffer.prefix(n))
                }
                guard bytes.count == manifest.st_size, bytes.last == 10 else { throw WorkspaceRecoveryError.unsafe("incomplete ownership manifest") }
                data = bytes
                close(manifestFD)
            } catch { close(manifestFD); throw error }
            let lines = data.split(separator: 10, omittingEmptySubsequences: false)
            guard lines.count >= 2, lines.count <= WorkspaceJournal.maxFiles + 2,
                  lines.last?.isEmpty == true, lines.dropLast().allSatisfy({ !$0.isEmpty && $0.count <= WorkspaceJournal.maxRecordBytes }) else {
                throw WorkspaceRecoveryError.unsafe("invalid manifest framing or record budget")
            }
            let decoder = JSONDecoder()
            guard case .header(let header) = try decoder.decode(WorkspaceRecord.self, from: Data(lines[0])),
                  header.version == 1, header.id == id, header.createdAt.timeIntervalSince1970.isFinite,
                  header.directory.valid, header.manifest.valid else { throw WorkspaceRecoveryError.unsafe("invalid manifest header") }
            // A remount may change dev/fsid. Only a matching persistent volume
            // UUID permits that; inode and birth time must still be unchanged.
            let allowDeviceChange = header.filesystem.volumeUUID != nil && header.filesystem.volumeUUID == filesystem.volumeUUID
            guard (allowDeviceChange || header.filesystem == filesystem),
                  header.directory.matches(directory, allowDeviceChange: allowDeviceChange),
                  header.manifest.matches(manifest, allowDeviceChange: allowDeviceChange) else { throw WorkspaceRecoveryError.unsafe("workspace or filesystem identity changed") }
            var files: [String: WorkspaceFileIdentity] = [:]
            for line in lines.dropFirst().dropLast() {
                guard case .file(let sequence, let filename, let identity) = try decoder.decode(WorkspaceRecord.self, from: Data(line)),
                      sequence == files.count + 1, WorkspaceJournal.validFileName(filename), identity.valid,
                      identity.uid == header.directory.uid, identity.device == header.directory.device,
                      files.updateValue(identity, forKey: filename) == nil else { throw WorkspaceRecoveryError.unsafe("invalid file ownership record") }
            }
            let children = try WorkspaceDirectory.entries(fd: fd, limit: WorkspaceJournal.maxFiles + 1)
            guard children.allSatisfy({ $0 == WorkspaceJournal.filename || files[$0] != nil }) else { throw WorkspaceRecoveryError.unsafe("unrecorded files remain") }
            var total: UInt64 = 0
            for (filename, identity) in files {
                var info = stat()
                if fstatat(fd, filename, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue } // interrupted cleanup
                    throw WorkspaceRecoveryError.io("inspect recorded file", errno)
                }
                guard identity.matches(info, allowDeviceChange: allowDeviceChange), info.st_dev == directory.st_dev,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1,
                      info.st_mode & 0o777 == 0o600, info.st_size >= 0 else { throw WorkspaceRecoveryError.unsafe("recorded file was replaced or linked") }
                let (sum, overflow) = total.addingReportingOverflow(UInt64(info.st_size))
                guard !overflow else { throw WorkspaceRecoveryError.budgetExceeded }; total = sum
            }
            let proof = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return Inspection(descriptor: fd, header: header, files: files, bytes: total, proof: proof, allowDeviceChange: allowDeviceChange)
        } catch { close(fd); throw error }
    }

    private static func cleanup(parent: URL, filesystem: MountedFilesystemIdentity, expectedParent: WorkspaceDirectoryIdentity, lockAt: URL,
                                leftover: DiskWorkspaceLeftover) throws {
        guard leftover.status == .recoverable, let proof = leftover.proof, proof.utf8.count == 64,
              leftover.path == parent.appendingPathComponent(leftover.name).path else { throw WorkspaceRecoveryError.changed }
        try withParent(parent: parent, filesystem: filesystem, expectedParent: expectedParent, lockAt: lockAt) { parentFD in
            let inspected = try inspect(parentFD: parentFD, name: leftover.name, filesystem: filesystem)
            defer { close(inspected.descriptor) }
            guard inspected.proof == proof else { throw WorkspaceRecoveryError.changed }
            var directory = stat()
            guard fstatat(parentFD, leftover.name, &directory, AT_SYMLINK_NOFOLLOW) == 0,
                  directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  inspected.header.directory.matches(directory, allowDeviceChange: inspected.allowDeviceChange) else { throw WorkspaceRecoveryError.changed }
            for (name, identity) in inspected.files {
                var info = stat()
                if fstatat(inspected.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                    if errno == ENOENT { continue }
                    throw WorkspaceRecoveryError.io("recheck recorded file", errno)
                }
                guard identity.matches(info, allowDeviceChange: inspected.allowDeviceChange), info.st_nlink == 1,
                      info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw WorkspaceRecoveryError.changed }
                guard unlinkat(inspected.descriptor, name, 0) == 0 else { throw WorkspaceRecoveryError.io("remove owned test file", errno) }
            }
            // Recheck the directory and manifest after deleting known files.
            guard try WorkspaceDirectory.entries(fd: inspected.descriptor, limit: WorkspaceJournal.maxFiles + 1) == [WorkspaceJournal.filename] else {
                throw WorkspaceRecoveryError.unsafe("directory contains unknown children")
            }
            var manifest = stat()
            guard fstatat(inspected.descriptor, WorkspaceJournal.filename, &manifest, AT_SYMLINK_NOFOLLOW) == 0,
                  inspected.header.manifest.matches(manifest, allowDeviceChange: inspected.allowDeviceChange),
                  manifest.st_nlink == 1 else { throw WorkspaceRecoveryError.changed }
            try WorkspaceJournal.synchronize(inspected.descriptor)
            guard unlinkat(inspected.descriptor, WorkspaceJournal.filename, 0) == 0 else { throw WorkspaceRecoveryError.io("remove owned manifest", errno) }
            guard fstatat(parentFD, leftover.name, &directory, AT_SYMLINK_NOFOLLOW) == 0,
                  inspected.header.directory.matches(directory, allowDeviceChange: inspected.allowDeviceChange),
                  unlinkat(parentFD, leftover.name, AT_REMOVEDIR) == 0 else { throw WorkspaceRecoveryError.changed }
            try WorkspaceJournal.synchronize(parentFD)
        }
    }
}
