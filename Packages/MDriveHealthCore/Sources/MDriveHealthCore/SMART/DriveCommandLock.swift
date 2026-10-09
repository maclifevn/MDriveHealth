/* Cross-process per-attachment command lock. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import Darwin

public enum DriveCommandLockError: Error, LocalizedError, Sendable {
    case busy, unsafePath, system(Int32)
    public var errorDescription: String? {
        switch self {
        case .busy: return "Another MDriveHealth process owns this device"
        case .unsafePath: return "Unsafe device-lock directory or file"
        case .system(let code): return "Device lock failed (\(code))"
        }
    }
}
public enum DriveCommandLock {
    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32
        public let token: UUID
        fileprivate init(_ fd: Int32, token: UUID) { self.fd = fd; self.token = token }
        func delegatedFD() throws -> Int32 {
            lock.lock(); defer { lock.unlock() }
            guard fd >= 0 else { throw DriveCommandLockError.unsafePath }; return fd
        }
        public func release() {
            lock.lock(); defer { lock.unlock() }
            // The same open-file description may be delegated to a worker.
            // Close our reference; do not unlock the worker's reference.
            if fd >= 0 { close(fd); fd = -1 }
        }
        deinit { release() }
    }
    public static func acquireAsync(registryEntryID: UInt64, directory: URL? = nil) async throws -> Lease {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try acquire(registryEntryID: registryEntryID, directory: directory) }) }
            thread.name = "MDriveHealth.device-lock"; thread.qualityOfService = .utility; thread.start()
        }
    }
    /// Nonblocking flock. Files are intentionally not unlinked: replacing a
    /// lock inode would let another process acquire a different lock.
    public static func withLock<T>(registryEntryID: UInt64, directory: URL? = nil,
                                   _ body: () throws -> T) throws -> T {
        try withLease(registryEntryID: registryEntryID, directory: directory) { _ in try body() }
    }
    public static func withLease<T>(registryEntryID: UInt64, directory: URL? = nil,
                                    _ body: (Lease) throws -> T) throws -> T {
        let lease = try acquire(registryEntryID: registryEntryID, directory: directory)
        defer { lease.release() }
        return try body(lease)
    }
    public static func acquire(registryEntryID: UInt64, directory: URL? = nil) throws -> Lease {
        guard registryEntryID != 0 else { throw DriveCommandLockError.unsafePath }
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-device-locks-v1")
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw DriveCommandLockError.system(errno) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DriveCommandLockError.system(errno) }; defer { close(parent) }
        var parentStat = stat()
        guard fstat(parent, &parentStat) == 0, parentStat.st_uid == getuid(), parentStat.st_mode & 0o077 == 0 else { throw DriveCommandLockError.unsafePath }
        let fd = openat(parent, "drive-\(registryEntryID).lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DriveCommandLockError.system(errno) }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw DriveCommandLockError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw errno == EWOULDBLOCK ? DriveCommandLockError.busy : DriveCommandLockError.system(errno) }
        let existing = try readRecord(fd)
        guard existing.isEmpty || validRecord(existing) else { throw DriveCommandLockError.unsafePath }
        let token = UUID(), bytes = Data("MDriveHealth-device-lock-v1\n\(getpid())\n\(token.uuidString)\n".utf8)
        guard ftruncate(fd, 0) == 0 else { throw DriveCommandLockError.system(errno) }
        let written = bytes.withUnsafeBytes { pwrite(fd, $0.baseAddress, bytes.count, 0) }
        guard written == bytes.count else { throw DriveCommandLockError.system(errno) }
        transferred = true
        return Lease(fd, token: token)
    }
    private static func readRecord(_ fd: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = pread(fd, &buffer, buffer.count, 0)
        guard length >= 0, length < buffer.count else { throw DriveCommandLockError.unsafePath }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }
    private static func validRecord(_ value: String) -> Bool {
        let parts = value.components(separatedBy: "\n")
        guard parts.count == 4, parts[0] == "MDriveHealth-device-lock-v1",
              let pid = Int32(parts[1]), pid > 0, String(pid) == parts[1],
              let token = UUID(uuidString: parts[2]), token.uuidString == parts[2], parts[3].isEmpty else { return false }
        return true
    }
    /// FD 3 is the parent's open-file description, explicitly inherited by
    /// this worker. It retains flock if the parent exits during IOKit I/O.
    static func validateDelegation(registryEntryID: UInt64, token: UUID, fd: Int32 = 3) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1,
              try readRecord(fd) == "MDriveHealth-device-lock-v1\n\(getppid())\n\(token.uuidString)\n",
              flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw DriveCommandLockError.unsafePath }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-device-locks-v1")
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw DriveCommandLockError.unsafePath }; defer { close(parent) }
        let expected = openat(parent, "drive-\(registryEntryID).lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard expected >= 0 else { throw DriveCommandLockError.unsafePath }; defer { close(expected) }
        var target = stat()
        guard fstat(expected, &target) == 0, target.st_dev == info.st_dev, target.st_ino == info.st_ino else { throw DriveCommandLockError.unsafePath }
    }
}
