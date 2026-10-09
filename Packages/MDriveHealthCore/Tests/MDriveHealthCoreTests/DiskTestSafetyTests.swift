import XCTest
import Darwin
@testable import MDriveHealthCore

final class DiskTestSafetyTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mdrive-safety-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private var volume: VolumeUsage {
        VolumeUsage(bsdName: "fixture", name: "Test fixture", mountPoint: root.path,
                    totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "fixture")
    }
    private var config: CapacityVerifyConfig {
        CapacityVerifyConfig(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384)
    }
    private func runFixture(_ io: CapacityFileIO = CapacityFileIO()) throws -> CapacityVerifyResult {
        try CapacityVerifier(io: io).run(in: root, volume: volume, config: config)
    }

    func testCapacityNeverReclaimsUnknownLegacyDirectory() throws {
        let legacy = root.appendingPathComponent(CapacityVerifier.testDirectoryName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        let sentinel = legacy.appendingPathComponent("data.txt")
        try Data("keep".utf8).write(to: sentinel)
        let result = try runFixture()
        XCTAssertEqual(result.verdict, .passedTestedRange)
        XCTAssertEqual(result.bytesRequested, 16384)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [CapacityVerifier.testDirectoryName])
    }

    func testBenchmarkRefusesExistingFileWithoutDeletingIt() throws {
        let sentinel = root.appendingPathComponent(BenchmarkLocation.testFileName)
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try DiskBenchmarkEngine().run(testFileURL: sentinel, volume: volume,
            config: BenchmarkConfig(fileSizeBytes: 8192, sequentialBlockBytes: 4096, includeRandomPhases: false),
            isCancelled: { false }, progress: { _ in })) { error in
            guard case BenchmarkError.fileCreationFailed(_, let code) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, EEXIST)
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testMissingDirectoryIsNeverRecreated() throws {
        let missing = root.appendingPathComponent("unmounted")
        XCTAssertThrowsError(try CapacityVerifier().run(in: missing, volume: volume, config: config)) {
            XCTAssertEqual($0 as? BenchmarkError, .volumeChanged(mountPoint: missing.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testProductionCannotUseUnverifiedVolumeSnapshot() throws {
        var acknowledged = config
        acknowledged.dataRiskAcknowledged = true
        XCTAssertThrowsError(try CapacityVerifier().run(volume: volume, config: acknowledged)) {
            XCTAssertEqual($0 as? BenchmarkError, .volumeChanged(mountPoint: self.root.path))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testProductionRefusesChangedMountedFilesystem() throws {
        let actual = try XCTUnwrap(MountedFilesystemIdentity.capture(at: URL(fileURLWithPath: "/")))
        let changed = MountedFilesystemIdentity(filesystemID: "changed", mountedFrom: actual.mountedFrom,
                                                mountedAt: actual.mountedAt, volumeUUID: actual.volumeUUID)
        let boot = VolumeUsage(bsdName: String(actual.mountedFrom.dropFirst(5)), name: "Boot", mountPoint: "/",
                               totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "boot",
                               mountIdentity: changed,
                               writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        XCTAssertThrowsError(try DiskTestWorkspace.open(volume: boot)) {
            XCTAssertEqual($0 as? BenchmarkError, .volumeChanged(mountPoint: "/"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testProductionBootWorkspaceUsesSameContainerWithoutWritingTestData() throws {
        let mount = try XCTUnwrap(MountedFilesystemIdentity.capture(at: URL(fileURLWithPath: "/")))
        let write = try XCTUnwrap(MountedFilesystemIdentity.capture(at: FileManager.default.temporaryDirectory))
        XCTAssertNotNil(mount.volumeUUID)
        XCTAssertNotNil(write.volumeUUID)
        let boot = VolumeUsage(bsdName: String(mount.mountedFrom.dropFirst(5)), name: "Boot", mountPoint: "/",
                               totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "boot",
                               mountIdentity: mount, writeIdentity: write, writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: FileManager.default.temporaryDirectory))
        let workspace = try DiskTestWorkspace.open(volume: boot)
        XCTAssertGreaterThan(try workspace.freeBytes(), 0)
        try workspace.cleanup() // only the empty directory owned by this test
    }

    func testBootWorkspaceCannotUseUnrelatedTemporaryFilesystem() throws {
        let mount = try XCTUnwrap(MountedFilesystemIdentity.capture(at: URL(fileURLWithPath: "/")))
        let write = try XCTUnwrap(MountedFilesystemIdentity.capture(at: root))
        let unrelated = MountedFilesystemIdentity(filesystemID: write.filesystemID, mountedFrom: "/dev/disk999s1",
                                                  mountedAt: write.mountedAt, volumeUUID: write.volumeUUID)
        let boot = VolumeUsage(bsdName: String(mount.mountedFrom.dropFirst(5)), name: "Boot", mountPoint: "/",
                               totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "boot",
                               mountIdentity: mount, writeIdentity: unrelated, writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: FileManager.default.temporaryDirectory))
        XCTAssertThrowsError(try DiskTestWorkspace.open(volume: boot)) {
            XCTAssertEqual($0 as? BenchmarkError, .volumeChanged(mountPoint: "/"))
        }
    }

    func testSymlinkDirectoryCannotRedirectWrites() throws {
        let destination = root.appendingPathComponent("destination")
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertThrowsError(try DiskTestWorkspace.fixture(at: link))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    func testCleanupRefusesReplacementInode() throws {
        let workspace = try DiskTestWorkspace.fixture(at: root)
        let fd = try workspace.createFile("data.bin")
        defer { close(fd) }
        let file = workspace.directoryURL.appendingPathComponent("data.bin")
        try FileManager.default.removeItem(at: file)
        try Data("replacement".utf8).write(to: file)
        XCTAssertThrowsError(try workspace.cleanup())
        XCTAssertEqual(try Data(contentsOf: file), Data("replacement".utf8))
    }

    func testRenamedWorkspaceCannotDeleteReplacementDirectory() throws {
        let workspace = try DiskTestWorkspace.fixture(at: root)
        let fd = try workspace.createFile("owned.bin")
        close(fd)
        let relocated = root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: workspace.directoryURL, to: relocated)
        try FileManager.default.createDirectory(at: workspace.directoryURL, withIntermediateDirectories: false)
        let sentinel = workspace.directoryURL.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        XCTAssertThrowsError(try workspace.cleanup())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocated.appendingPathComponent("owned.bin").path))
    }

    func testReadAndCleanupRejectReplacementSymlink() throws {
        let workspace = try DiskTestWorkspace.fixture(at: root)
        let fd = try workspace.createFile("data.bin")
        defer { close(fd) }
        let sentinel = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let file = workspace.directoryURL.appendingPathComponent("data.bin")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sentinel)
        XCTAssertThrowsError(try workspace.openFile("data.bin"))
        XCTAssertThrowsError(try workspace.cleanup())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testVolumeLockIsEffectiveAcrossProcesses() throws {
        let source = root.appendingPathComponent("lock-child.c")
        let binary = root.appendingPathComponent("lock-child")
        try """
        #include <sys/file.h>
        #include <fcntl.h>
        #include <errno.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc != 2) return 2;
            int fd = open(argv[1], O_RDONLY | O_DIRECTORY);
            if (fd < 0) return 2;
            int result = flock(fd, LOCK_EX | LOCK_NB);
            int blocked = result == -1 && errno == EWOULDBLOCK;
            close(fd);
            return blocked ? 0 : 1;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-Wall", "-Werror", source.path, "-o", binary.path]
        try compiler.run()
        compiler.waitUntilExit()
        XCTAssertEqual(compiler.terminationStatus, 0)
        guard compiler.terminationStatus == 0 else { return }
        var workspace: DiskTestWorkspace? = try DiskTestWorkspace.fixture(at: root)
        try withExtendedLifetime(workspace) {
            let child = Process()
            child.executableURL = binary
            child.arguments = [root.path]
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 0, "another process must be excluded")
            XCTAssertThrowsError(try DiskTestWorkspace.fixture(at: root)) {
                XCTAssertEqual($0 as? BenchmarkError, .alreadyRunning)
            }
            try workspace?.cleanup()
        }
        workspace = nil
        let next = try DiskTestWorkspace.fixture(at: root)
        try next.cleanup()
    }

    func testZeroWriteENOSPCCannotPass() throws {
        var io = CapacityFileIO()
        io.write = { _, _, _, _ in errno = ENOSPC; return -1 }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.bytesWritten, 0)
        XCTAssertEqual(result.bytesVerifiedOK, 0)
        XCTAssertEqual(result.interruption, .spaceExhausted)
    }

    func testPartialWriteCannotPassRequestedRange() throws {
        var io = CapacityFileIO()
        io.write = { fd, data, _, offset in pwrite(fd, data, 2048, offset) }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.bytesWritten, 2048)
        XCTAssertEqual(result.bytesRequested, 16384)
        XCTAssertEqual(result.interruption, .shortWrite)
    }

    func testWriteFailurePreservesPartialEvidence() throws {
        var calls = 0
        var io = CapacityFileIO()
        io.write = { fd, data, length, offset in
            calls += 1
            if calls == 2 { errno = EIO; return -1 }
            return pwrite(fd, data, length, offset)
        }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.bytesWritten, 4096)
        XCTAssertEqual(result.bytesVerifiedOK, 4096)
        XCTAssertEqual(result.interruption, .writeFailed)
    }

    func testFailedFlushCannotPassEvenWhenBytesMatch() throws {
        var io = CapacityFileIO()
        io.flush = { _ in errno = EIO; return -1 }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.bytesVerifiedOK, result.bytesWritten)
        XCTAssertEqual(result.interruption, .flushFailed)
    }

    func testCacheControlFailureCannotPass() throws {
        var io = CapacityFileIO()
        io.noCache = { _ in errno = EINVAL; return -1 }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.bytesWritten, 0)
        XCTAssertEqual(result.interruption, .cacheUnavailable)
    }

    func testReadFailureCannotPass() throws {
        var io = CapacityFileIO()
        io.read = { _, _, _, _ in errno = EIO; return -1 }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .inconclusive)
        XCTAssertEqual(result.bytesWritten, 16384)
        XCTAssertEqual(result.bytesVerifiedOK, 0)
        XCTAssertEqual(result.interruption, .readFailed)
    }

    func testInterruptedIOIsRetried() throws {
        var writes = 0, reads = 0
        var io = CapacityFileIO()
        io.write = { fd, data, length, offset in
            writes += 1
            if writes == 1 { errno = EINTR; return -1 }
            return pwrite(fd, data, length, offset)
        }
        io.read = { fd, data, length, offset in
            reads += 1
            if reads == 1 { errno = EINTR; return -1 }
            return pread(fd, data, length, offset)
        }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .passedTestedRange)
        XCTAssertEqual(result.bytesVerifiedOK, 16384)
        XCTAssertEqual(writes, 5)
        XCTAssertEqual(reads, 5)
    }

    func testCorruptionAtZeroOffsetIsCorruptionNotPhysicalCapacity() throws {
        var reads = 0
        var io = CapacityFileIO()
        io.read = { fd, data, length, offset in
            let count = pread(fd, data, length, offset)
            reads += 1
            if reads == 1, count > 0 { data.storeBytes(of: data.load(as: UInt8.self) ^ 1, as: UInt8.self) }
            return count
        }
        let result = try runFixture(io)
        XCTAssertEqual(result.verdict, .dataCorrupted)
        XCTAssertEqual(result.firstCorruptionOffset, 0)
        XCTAssertEqual(result.corruptedBlocks, 1)
        XCTAssertEqual(result.bytesVerifiedOK, 12288)
    }

    func testCapacityRequiresRiskAcknowledgementBeforeWriting() throws {
        XCTAssertThrowsError(try CapacityVerifier().run(volume: volume, config: config)) {
            XCTAssertEqual($0 as? BenchmarkError, .capacityRiskNotAcknowledged)
        }
        var acknowledged = config
        acknowledged.dataRiskAcknowledged = true
        let shared = VolumeUsage(bsdName: "fixture", name: "Shared", mountPoint: root.path,
                                 totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "container")
        XCTAssertThrowsError(try CapacityVerifier().run(volume: shared, config: acknowledged)) {
            XCTAssertEqual($0 as? BenchmarkError, .capacityRiskNotAcknowledged)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    func testBootCapacityTestIsRefusedEvenWithConsent() throws {
        let boot = VolumeUsage(bsdName: "boot", name: "Boot", mountPoint: "/", totalBytes: 1 << 40,
                               availableBytes: 1 << 40, sharedCapacityKey: "boot")
        var acknowledged = config
        acknowledged.dataRiskAcknowledged = true
        acknowledged.sharedCapacityRiskAcknowledged = true
        XCTAssertThrowsError(try CapacityVerifier().run(volume: boot, config: acknowledged)) {
            XCTAssertEqual($0 as? BenchmarkError, .unsafeCapacityTarget)
        }
    }

    func testInvalidBudgetsAreRejectedWithoutAllocation() {
        for value in [Double.nan, .infinity, -.infinity, 0, -1, 301] {
            XCTAssertThrowsError(try BenchmarkConfig(randomPhaseSeconds: value).validate())
        }
        XCTAssertThrowsError(try CapacityVerifyConfig(reserveBytes: .max).validate())
        XCTAssertThrowsError(try CapacityVerifyConfig(fileSizeBytes: 1 << 30, blockBytes: 16 << 20).validate())
    }
}
