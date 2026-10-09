/* Persistent ownership of temporary measurement files. GPL-3.0-or-later. */
import Foundation
import Darwin

struct WorkspaceFileIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let uid: UInt32
    let birthSeconds: Int64
    let birthNanoseconds: Int64

    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; uid = info.st_uid
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }
    func matches(_ info: stat, allowDeviceChange: Bool = false) -> Bool {
        (allowDeviceChange || device == info.st_dev) && inode == info.st_ino && uid == info.st_uid
            && birthSeconds == info.st_birthtimespec.tv_sec && birthNanoseconds == info.st_birthtimespec.tv_nsec
    }
    var valid: Bool { inode > 0 && birthSeconds > 0 && (0..<1_000_000_000).contains(birthNanoseconds) }
}

struct WorkspaceHeader: Codable, Sendable {
    let version: Int
    let id: UUID
    let nonce: UUID
    let createdAt: Date
    let filesystem: MountedFilesystemIdentity
    let directory: WorkspaceFileIdentity
    let manifest: WorkspaceFileIdentity
}
enum WorkspaceRecord: Codable {
    case header(WorkspaceHeader)
    case file(sequence: Int, name: String, identity: WorkspaceFileIdentity)
}
struct WorkspaceJournalIO {
    var write: (Int32, UnsafeRawPointer, Int) -> Int = { Darwin.write($0, $1, $2) }
    var synchronize: (Int32) -> Int32 = { fsync($0) }
}

/// Append-only, bounded NDJSON. A record is synchronized before the engine
/// receives the file descriptor and can put measurement data into that file.
final class WorkspaceJournal {
    static let prefix = ".com.maclife.mdrivehealth.test-"
    static let filename = "ownership-v1.ndjson"
    static let maxFiles = 131_072
    static let maxBytes = 64 * 1_048_576
    static let maxRecordBytes = 4096
    let identity: WorkspaceFileIdentity
    private var descriptor: Int32
    private var bytes = 0
    private var count = 0
    private var failed = false
    private let io: WorkspaceJournalIO

    init(directoryFD: Int32, name: String, directory: stat, filesystem: MountedFilesystemIdentity,
         io: WorkspaceJournalIO = .init()) throws {
        self.io = io
        guard let id = UUID(uuidString: String(name.dropFirst(Self.prefix.count))),
              name == Self.prefix + id.uuidString,
              directory.st_uid == geteuid(), directory.st_mode & 0o777 == 0o700,
              WorkspaceFileIdentity(directory).valid else {
            throw BenchmarkError.invalidConfiguration("Filesystem cannot preserve private workspace ownership")
        }
        descriptor = openat(directoryFD, Self.filename, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BenchmarkError.ioFailed(operation: "create ownership manifest", errno: errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_nlink == 1,
              info.st_dev == directory.st_dev, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o777 == 0o600, WorkspaceFileIdentity(info).valid else {
            close(descriptor)
            // Do not unlink a path whose identity could not be verified.
            throw BenchmarkError.cleanupFailed(path: name)
        }
        identity = WorkspaceFileIdentity(info)
        do {
            try append(.header(.init(version: 1, id: id, nonce: UUID(), createdAt: Date(),
                                     filesystem: filesystem, directory: WorkspaceFileIdentity(directory), manifest: identity)))
            try Self.synchronize(directoryFD, using: io)
        } catch {
            // Init failure cannot run deinit. Only remove the inode we created.
            var current = stat()
            if fstatat(directoryFD, Self.filename, &current, AT_SYMLINK_NOFOLLOW) == 0, identity.matches(current) {
                _ = unlinkat(directoryFD, Self.filename, 0)
            }
            close(descriptor)
            descriptor = -1
            throw error
        }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }

    static func validFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 128 && name != "." && name != ".." && name != filename
            && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
    }
    func record(name: String, identity: WorkspaceFileIdentity, directoryFD: Int32) throws {
        guard count < Self.maxFiles, Self.validFileName(name), identity.valid else {
            throw BenchmarkError.invalidConfiguration("Temporary file ownership budget exceeded or invalid filename")
        }
        try validate(directoryFD: directoryFD)
        try append(.file(sequence: count + 1, name: name, identity: identity))
        try validate(directoryFD: directoryFD)
        count += 1
    }
    func synchronizeCreation(fileFD: Int32, directoryFD: Int32) throws {
        try Self.synchronize(fileFD, using: io)
        try Self.synchronize(directoryFD, using: io)
    }
    private func validate(directoryFD: Int32) throws {
        var info = stat()
        guard fstatat(directoryFD, Self.filename, &info, AT_SYMLINK_NOFOLLOW) == 0,
              identity.matches(info), info.st_nlink == 1, info.st_size == bytes,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            failed = true
            throw BenchmarkError.ioFailed(operation: "ownership manifest changed", errno: EIO)
        }
    }
    private func append(_ record: WorkspaceRecord) throws {
        guard !failed else { throw BenchmarkError.ioFailed(operation: "ownership manifest is incomplete", errno: EIO) }
        var data = try JSONEncoder().encode(record)
        guard data.count <= Self.maxRecordBytes, bytes + data.count + 1 <= Self.maxBytes else {
            throw BenchmarkError.invalidConfiguration("Temporary file ownership manifest budget exceeded")
        }
        data.append(10)
        do {
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = io.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw BenchmarkError.ioFailed(operation: "write ownership manifest", errno: n == 0 ? EIO : errno) }
                    offset += n
                }
            }
            try Self.synchronize(descriptor, using: io)
            bytes += data.count
        } catch { failed = true; throw error }
    }
    static func synchronize(_ fd: Int32, using io: WorkspaceJournalIO = .init()) throws {
        while io.synchronize(fd) != 0 {
            if errno == EINTR { continue }
            throw BenchmarkError.ioFailed(operation: "synchronize ownership metadata", errno: errno)
        }
    }
}
