/*
 * DiskTestWorkspace.swift — descriptor-bound, exclusively owned test files.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import Foundation
import Darwin

/// The opened write directory, independent of its pathname. Birth time also
/// rejects inode reuse. Capture on a supervised worker, before a measurement.
public struct WorkspaceDirectoryIdentity: Sendable, Codable, Hashable {
    public let device: Int32
    public let inode: UInt64
    public let ownerUID: UInt32
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; ownerUID = info.st_uid
        birthSeconds = Int64(info.st_birthtimespec.tv_sec)
        birthNanoseconds = Int64(info.st_birthtimespec.tv_nsec)
    }
    public var isValid: Bool { inode > 0 && birthSeconds > 0 && (0..<1_000_000_000).contains(birthNanoseconds) }
    /// Only a separately verified, equal persistent volume UUID permits a
    /// device number change after remount. Directory identity remains exact.
    public func matches(_ other: Self, allowDeviceChange: Bool = false) -> Bool {
        isValid && other.isValid && (allowDeviceChange || device == other.device)
            && inode == other.inode && ownerUID == other.ownerUID
            && birthSeconds == other.birthSeconds && birthNanoseconds == other.birthNanoseconds
    }
    public static func capture(at url: URL) -> Self? {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return capture(descriptor: fd)
    }
    static func capture(descriptor: Int32) -> Self? {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { return nil }
        let identity = Self(info)
        return identity.isValid ? identity : nil
    }
}

/// Captured at discovery, before a user chooses a volume. A path alone is
/// insufficient: unplug/replug can reuse it for a different filesystem.
public struct MountedFilesystemIdentity: Sendable, Codable, Hashable {
    public let filesystemID: String
    public let mountedFrom: String
    public let mountedAt: String
    public let volumeUUID: String?

    static func capture(at url: URL) -> MountedFilesystemIdentity? {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return identity(info, uuid: uuid)
    }

    static func identity(_ info: statfs, uuid: String? = nil) -> Self {
        var fsid = info.f_fsid
        return Self(filesystemID: withUnsafeBytes(of: &fsid) { Data($0).base64EncodedString() },
                    mountedFrom: fixedString(info.f_mntfromname),
                    mountedAt: fixedString(info.f_mntonname), volumeUUID: uuid)
    }

    func matches(_ info: statfs) -> Bool {
        let actual = Self.identity(info)
        return filesystemID == actual.filesystemID
            && mountedFrom == actual.mountedFrom && mountedAt == actual.mountedAt
    }
}

/// Kept on the blocking worker thread. Cleanup never traverses directories
/// or unlinks a pathname that has been replaced since this session created it.
final class DiskTestWorkspace {
    let directoryURL: URL
    private let parentFD: Int32
    private let directoryFD: Int32
    private let lockFD: Int32
    private let directoryName: String?
    private let directoryIdentity: WorkspaceFileIdentity
    private let filesystemIdentity: MountedFilesystemIdentity
    private var files: [String: WorkspaceFileIdentity] = [:]
    private var journal: WorkspaceJournal?
    private var cleaned = false
    private let ownsDirectory: Bool
    private let cleanupProgress: @Sendable (Int) -> Void
    private var cleanupStarted = false
    private var removedFiles = 0

    static func open(volume: VolumeUsage, sessionID: UUID = UUID(), cleanupProgress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> DiskTestWorkspace {
        let location = try validatedLocation(volume: volume)
        return try make(parent: location.parent, expected: location.identity, expectedDirectory: location.directoryIdentity, lockAt: location.lockAt, sessionID: sessionID, cleanupProgress: cleanupProgress)
    }

    static func validatedLocation(volume: VolumeUsage) throws -> (parent: URL, identity: MountedFilesystemIdentity, directoryIdentity: WorkspaceDirectoryIdentity, lockAt: URL) {
        guard let selected = volume.mountIdentity, let write = volume.writeIdentity,
              let directory = volume.writeDirectoryIdentity, directory.isValid else {
            throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint)
        }
        guard selected.volumeUUID != nil, write.volumeUUID != nil else {
            throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint)
        }
        if volume.mountPoint == "/" {
            // TMPDIR may be overridden. A boot benchmark must still write to
            // the boot APFS container, never an unrelated external temp dir.
            guard write.mountedFrom.hasPrefix("/dev/disk"),
                  VolumeUsageReader.containerKey(for: String(write.mountedFrom.dropFirst(5)))
                    == VolumeUsageReader.containerKey(for: volume.bsdName) else {
                throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint)
            }
        } else if selected != write {
            throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint)
        }
        let mountURL = URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
        // Validate the selected mounted filesystem, including a boot snapshot.
        let mountFD = Darwin.open(mountURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard mountFD >= 0 else { throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint) }
        defer { close(mountFD) }
        var mountInfo = statfs()
        guard fstatfs(mountFD, &mountInfo) == 0, selected.matches(mountInfo),
              selected.mountedAt == volume.mountPoint,
              selected.mountedFrom == "/dev/\(volume.bsdName)",
              MountedFilesystemIdentity.capture(at: mountURL)?.volumeUUID == selected.volumeUUID else {
            throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint)
        }
        let parent = BenchmarkLocation.writeDirectory(for: volume)
        guard MountedFilesystemIdentity.capture(at: parent) == write,
              WorkspaceDirectoryIdentity.capture(at: parent) == directory else {
            throw BenchmarkError.volumeChanged(mountPoint: volume.mountPoint)
        }
        return (parent, write, directory, URL(fileURLWithPath: write.mountedAt, isDirectory: true))
    }

    /// Explicit fixture seam. Production entry points always use open(volume:).
    static func fixture(at directory: URL, createSession: Bool = true, journalIO: WorkspaceJournalIO = .init(),
                        sessionID: UUID = UUID(), expectedDirectory: WorkspaceDirectoryIdentity? = nil,
                        cleanupProgress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> DiskTestWorkspace {
        guard let identity = MountedFilesystemIdentity.capture(at: directory),
              let directoryIdentity = expectedDirectory ?? WorkspaceDirectoryIdentity.capture(at: directory) else {
            throw BenchmarkError.volumeChanged(mountPoint: directory.path)
        }
        return try make(parent: directory, expected: identity, expectedDirectory: directoryIdentity,
                        lockAt: createSession ? directory : nil, createSession: createSession, journalIO: journalIO, sessionID: sessionID, cleanupProgress: cleanupProgress)
    }

    private static func make(parent: URL, expected: MountedFilesystemIdentity, expectedDirectory: WorkspaceDirectoryIdentity,
                             lockAt: URL?, createSession: Bool = true, journalIO: WorkspaceJournalIO = .init(),
                             sessionID: UUID = UUID(), cleanupProgress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> DiskTestWorkspace {
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw BenchmarkError.volumeChanged(mountPoint: parent.path) }
        var lockFD: Int32 = -1
        var directoryFD: Int32 = -1
        var name: String?
        var transferred = false
        do {
            var info = statfs()
            guard fstatfs(parentFD, &info) == 0, expected.matches(info),
                  WorkspaceDirectoryIdentity.capture(descriptor: parentFD) == expectedDirectory else {
                throw BenchmarkError.volumeChanged(mountPoint: parent.path)
            }
            guard info.f_flags & UInt32(MNT_RDONLY) == 0 else {
                throw BenchmarkError.volumeNotWritable(mountPoint: parent.path)
            }
            if let lockAt {
                lockFD = Darwin.open(lockAt.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                var lockInfo = statfs()
                guard lockFD >= 0, fstatfs(lockFD, &lockInfo) == 0, expected.matches(lockInfo),
                      lockAt.path != parent.path || WorkspaceDirectoryIdentity.capture(descriptor: lockFD) == expectedDirectory else {
                    throw BenchmarkError.volumeChanged(mountPoint: parent.path)
                }
                // A directory vnode lock is shared across processes and users;
                // no fixed lock file can be replaced or removed underneath it.
                guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK { throw BenchmarkError.alreadyRunning }
                    throw BenchmarkError.ioFailed(operation: "flock", errno: errno)
                }
            }
            if createSession {
                let session = WorkspaceJournal.prefix + sessionID.uuidString
                guard mkdirat(parentFD, session, 0o700) == 0 else {
                    throw BenchmarkError.fileCreationFailed(path: parent.path, errno: errno)
                }
                name = session
                directoryFD = openat(parentFD, session, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            } else {
                directoryFD = dup(parentFD)
            }
            var directoryInfo = stat()
            guard directoryFD >= 0, fstat(directoryFD, &directoryInfo) == 0 else {
                throw BenchmarkError.ioFailed(operation: "open test directory", errno: errno)
            }
            let workspace = DiskTestWorkspace(parent: parent, parentFD: parentFD, directoryFD: directoryFD,
                                              lockFD: lockFD, name: name, info: directoryInfo,
                                              filesystem: expected, ownsDirectory: createSession, cleanupProgress: cleanupProgress)
            // Descriptor ownership transfers before any throwing journal I/O.
            directoryFD = -1; lockFD = -1
            transferred = true
            if let name {
                workspace.journal = try WorkspaceJournal(directoryFD: workspace.directoryFD, name: name,
                    directory: directoryInfo, filesystem: expected, io: journalIO)
                try WorkspaceJournal.synchronize(workspace.parentFD)
            }
            return workspace
        } catch {
            // If ownership transferred, workspace deinit has closed parentFD.
            if transferred { throw error }
            if directoryFD >= 0 { close(directoryFD) }
            // Only our freshly created, still empty directory; never recurse.
            if let name { _ = unlinkat(parentFD, name, AT_REMOVEDIR) }
            if lockFD >= 0 { close(lockFD) }
            close(parentFD)
            throw error
        }
    }

    private init(parent: URL, parentFD: Int32, directoryFD: Int32, lockFD: Int32,
                 name: String?, info: stat, filesystem: MountedFilesystemIdentity,
                 ownsDirectory: Bool, cleanupProgress: @escaping @Sendable (Int) -> Void) {
        self.parentFD = parentFD; self.directoryFD = directoryFD; self.lockFD = lockFD
        directoryName = name; directoryIdentity = WorkspaceFileIdentity(info)
        filesystemIdentity = filesystem; self.ownsDirectory = ownsDirectory
        self.cleanupProgress = cleanupProgress
        directoryURL = name.map { parent.appendingPathComponent($0, isDirectory: true) } ?? parent
    }

    deinit {
        if ownsDirectory { try? cleanup() }
        close(directoryFD); close(parentFD)
        if lockFD >= 0 { close(lockFD) }
    }

    func validateFilesystem() throws {
        var info = statfs()
        guard fstatfs(directoryFD, &info) == 0, filesystemIdentity.matches(info) else {
            throw BenchmarkError.volumeChanged(mountPoint: directoryURL.path)
        }
        if let directoryName {
            var directory = stat()
            guard fstatat(parentFD, directoryName, &directory, AT_SYMLINK_NOFOLLOW) == 0,
                  directoryIdentity.matches(directory), directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
                throw BenchmarkError.volumeChanged(mountPoint: directoryURL.path)
            }
        }
    }

    func freeBytes() throws -> UInt64 {
        try validateFilesystem()
        var info = statfs()
        guard fstatfs(directoryFD, &info) == 0, info.f_bsize > 0 else {
            throw BenchmarkError.ioFailed(operation: "fstatfs", errno: errno)
        }
        // Use currently free blocks, not purgeable space or a cached estimate.
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow else { throw BenchmarkError.invalidConfiguration("free space overflow") }
        return bytes
    }

    func filesystemType() throws -> String {
        try validateFilesystem()
        var info = statfs()
        guard fstatfs(directoryFD, &info) == 0 else {
            throw BenchmarkError.ioFailed(operation: "fstatfs", errno: errno)
        }
        return fixedString(info.f_fstypename)
    }

    func createFile(_ name: String) throws -> Int32 {
        try validateFilesystem()
        guard WorkspaceJournal.validFileName(name), files.count < WorkspaceJournal.maxFiles else {
            throw BenchmarkError.invalidConfiguration("invalid test filename")
        }
        let fd = openat(directoryFD, name, O_CREAT | O_RDWR | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw BenchmarkError.fileCreationFailed(path: directoryURL.appendingPathComponent(name).path, errno: errno)
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1, info.st_dev == directoryIdentity.device, WorkspaceFileIdentity(info).valid else {
            close(fd)
            throw BenchmarkError.ioFailed(operation: "validate test file", errno: EIO)
        }
        files[name] = WorkspaceFileIdentity(info)
        do {
            if let journal {
                try journal.synchronizeCreation(fileFD: fd, directoryFD: directoryFD)
                try journal.record(name: name, identity: WorkspaceFileIdentity(info), directoryFD: directoryFD)
            }
        } catch { close(fd); throw error }
        return fd
    }

    func openFile(_ name: String) throws -> Int32 {
        try validateFilesystem()
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else {
            throw BenchmarkError.invalidConfiguration("invalid test filename")
        }
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BenchmarkError.ioFailed(operation: "open test file", errno: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_dev == directoryIdentity.device,
              (files[name]?.matches(info) ?? !ownsDirectory) else {
            close(fd)
            throw BenchmarkError.ioFailed(operation: "test file identity changed", errno: EIO)
        }
        return fd
    }

    /// The fixture seam can clean its one created file without owning the
    /// fixture's parent. Production sessions additionally remove their directory.
    func cleanup() throws {
        guard !cleaned else { return }
        if !cleanupStarted { cleanupStarted = true; cleanupProgress(0) }
        if let journal {
            var info = stat()
            guard fstatat(directoryFD, WorkspaceJournal.filename, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  journal.identity.matches(info), info.st_nlink == 1,
                  info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw BenchmarkError.cleanupFailed(path: directoryURL.path)
            }
        }
        for (name, identity) in files {
            var info = stat()
            if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw BenchmarkError.cleanupFailed(path: directoryURL.path)
            }
            guard identity.matches(info), info.st_nlink == 1, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                throw BenchmarkError.cleanupFailed(path: directoryURL.path)
            }
            guard unlinkat(directoryFD, name, 0) == 0 else {
                throw BenchmarkError.cleanupFailed(path: directoryURL.path)
            }
            removedFiles += 1; cleanupProgress(removedFiles)
        }
        if let name = directoryName {
            // Preserve the manifest if unknown children prevent removing this
            // directory. No recursive deletion or guessing about ownership.
            let children: [String]
            do { children = try WorkspaceDirectory.entries(fd: directoryFD, limit: WorkspaceJournal.maxFiles + 2) }
            catch { throw BenchmarkError.cleanupFailed(path: directoryURL.path) }
            guard children.allSatisfy({ $0 == WorkspaceJournal.filename }) else {
                throw BenchmarkError.cleanupFailed(path: directoryURL.path)
            }
            if journal != nil {
                guard unlinkat(directoryFD, WorkspaceJournal.filename, 0) == 0 else {
                    throw BenchmarkError.cleanupFailed(path: directoryURL.path)
                }
            }
            var info = stat()
            guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  directoryIdentity.matches(info), unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else {
                throw BenchmarkError.cleanupFailed(path: directoryURL.path)
            }
        }
        cleaned = true
    }

    func withCleanup<T>(_ work: () throws -> T) throws -> T {
        do {
            let result = try work()
            try cleanup()
            return result
        } catch {
            let original = error
            // A cleanup error takes precedence: the user needs to know where
            // test files remain even when the original operation was cancelled.
            try cleanup()
            throw original
        }
    }
}
