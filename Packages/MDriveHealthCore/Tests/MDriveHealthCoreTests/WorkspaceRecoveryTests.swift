/* Actual SIGKILL fixtures plus ownership/fault tests. GPL-3.0-or-later. */
import XCTest
import Darwin
@testable import MDriveHealthCore

final class WorkspaceRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        if let child = ProcessInfo.processInfo.environment["MDRIVE_RECOVERY_FIXTURE_ROOT"] {
            root = URL(fileURLWithPath: child); return
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mdrive-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside-must-survive".utf8).write(to: root.appendingPathComponent("outside.txt"))
    }
    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["MDRIVE_RECOVERY_FIXTURE_ROOT"] == nil {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("outside.txt")), Data("outside-must-survive".utf8))
            try FileManager.default.removeItem(at: root)
        }
    }
    private func scan() throws -> DiskWorkspaceScan { try DiskWorkspaceRecovery.scanFixture(at: root) }
    private func entry() throws -> DiskWorkspaceLeftover { try XCTUnwrap(scan().leftovers.first) }
    private func manifest(_ path: URL) -> URL { path.appendingPathComponent(WorkspaceJournal.filename) }
    private func replaceManifest(_ path: URL, transform: (Data) throws -> Data) throws {
        let url = manifest(path)
        let data = try transform(Data(contentsOf: url))
        // In-place change preserves inode, so this tests framing/content guards.
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: data); try handle.synchronize()
    }
    private func killFixture(_ stage: String) throws -> URL {
        let child = Process()
        let runner = try BoundedProcess.run(ProcessCommand("/usr/bin/xcrun", ["--find", "xctest"], timeout: 5, scope: "recovery-test-runner")).requireSuccess()
        child.executableURL = URL(fileURLWithPath: String(decoding: runner, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        child.arguments = ["-XCTest", "MDriveHealthCoreTests.WorkspaceRecoveryTests/testCrashFixtureChild", Bundle(for: Self.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment["MDRIVE_RECOVERY_FIXTURE_ROOT"] = root.path
        environment["MDRIVE_RECOVERY_FIXTURE_STAGE"] = stage
        // The sanitizer must load before a sanitized XCTest bundle in the new
        // unsanitized xctest host, just as SwiftPM arranges for the parent host.
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_init") {
            var location = Dl_info()
            if dladdr(symbol, &location) != 0, let filename = location.dli_fname {
                let runtime = String(cString: filename)
                var libraries = (environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
                if !libraries.contains(runtime) { libraries.insert(runtime, at: 0) }
                environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
            }
        }
        child.environment = environment
        let diagnostic = root.appendingPathComponent("child-stderr.txt")
        XCTAssertTrue(FileManager.default.createFile(atPath: diagnostic.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        let stderr = try FileHandle(forWritingTo: diagnostic); defer { try? stderr.close() }
        child.standardOutput = FileHandle.nullDevice; child.standardError = stderr
        let ready = root.appendingPathComponent("ready")
        try? FileManager.default.removeItem(at: ready)
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: ready.path), child.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard FileManager.default.fileExists(atPath: ready.path) else {
            let detail = String(decoding: try Data(contentsOf: diagnostic).prefix(4096), as: UTF8.self)
            XCTFail("Child must reach the explicit \(stage) handshake before kill: \(detail)")
            throw WorkspaceRecoveryError.unsafe("fixture did not reach handshake")
        }
        let path = try String(contentsOf: ready, encoding: .utf8)
        XCTAssertThrowsError(try scan()) {
            guard case WorkspaceRecoveryError.busy = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal); XCTAssertEqual(child.terminationStatus, SIGKILL)
        return URL(fileURLWithPath: path)
    }

    /// Launched as the sole test in a fresh process; never forks XCTest threads.
    func testCrashFixtureChild() throws {
        guard let stage = ProcessInfo.processInfo.environment["MDRIVE_RECOVERY_FIXTURE_STAGE"] else { return }
        func stop(_ directory: URL) throws {
            try Data(directory.path.utf8).write(to: root.appendingPathComponent("ready"), options: .atomic)
            raise(SIGSTOP)
            XCTFail("The parent must SIGKILL this stopped process")
        }
        var calls = 0
        var io = WorkspaceJournalIO()
        io.write = { fd, pointer, count in
            calls += 1
            if calls == 2 && (stage == "unrecorded" || stage == "torn-record") {
                if stage == "torn-record" { _ = Darwin.write(fd, pointer, max(1, count / 2)) }
                let names = try! FileManager.default.contentsOfDirectory(atPath: self.root.path)
                let directory = self.root.appendingPathComponent(names.first(where: { $0.hasPrefix(WorkspaceJournal.prefix) })!)
                try! stop(directory)
            }
            return Darwin.write(fd, pointer, count)
        }
        let workspace = try DiskTestWorkspace.fixture(at: root, journalIO: io)
        if stage == "header" { try stop(workspace.directoryURL) }
        let first = try workspace.createFile("first.bin")
        if stage == "created" { try stop(workspace.directoryURL) }
        let bytes = [UInt8](repeating: 0xA5, count: 8192)
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(first, $0.baseAddress!, $0.count) }, bytes.count)
        close(first)
        let second = try workspace.createFile("second.bin")
        XCTAssertEqual(bytes.withUnsafeBytes { Darwin.write(second, $0.baseAddress!, $0.count) }, bytes.count)
        close(second)
        if stage == "partly-cleaned" { XCTAssertEqual(unlink(workspace.directoryURL.appendingPathComponent("first.bin").path), 0) }
        try stop(workspace.directoryURL)
        withExtendedLifetime(workspace) {}
    }
    func testKilledAfterHeaderRecoversEmptyOwnedDirectory() throws {
        let path = try killFixture("header"), found = try entry()
        XCTAssertEqual(found.status, .recoverable); XCTAssertEqual(found.fileCount, 0); XCTAssertEqual(found.bytes, 0)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path)); XCTAssertTrue(try scan().leftovers.isEmpty)
    }
    func testFileOwnershipIsDurableBeforeFirstDataWrite() throws {
        let path = try killFixture("created"), found = try entry()
        XCTAssertEqual(found.status, .recoverable); XCTAssertEqual(found.fileCount, 1); XCTAssertEqual(found.bytes, 0)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("first.bin")).count, 0)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found)
    }
    func testKilledAfterWritesReportsExactRangeAndOnlyDeletesOwnedFiles() throws {
        let path = try killFixture("filled"), found = try entry()
        XCTAssertEqual(found.status, .recoverable); XCTAssertEqual(found.fileCount, 2); XCTAssertEqual(found.bytes, 16384)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testRecoveryCanResumeAfterPartialCleanup() throws {
        _ = try killFixture("partly-cleaned")
        let found = try entry(); XCTAssertEqual(found.status, .recoverable); XCTAssertEqual(found.bytes, 8192)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found)
        XCTAssertTrue(try scan().leftovers.isEmpty)
    }
    func testKillBeforeFileRecordPreservesUnrecordedFileAndReportsUnknown() throws {
        let path = try killFixture("unrecorded"), found = try entry()
        XCTAssertEqual(found.status, .unverified); XCTAssertNil(found.proof); XCTAssertNil(found.bytes)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent("first.bin").path))
    }
    func testTornJournalNeverBecomesRecoverable() throws {
        let path = try killFixture("torn-record"), found = try entry()
        XCTAssertEqual(found.status, .unverified); XCTAssertTrue(found.diagnostic?.contains("incomplete") == true)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest(path).path))
    }
    func testReplacementFileFailsBeforeDeletingAnyOtherFile() throws {
        let path = try killFixture("filled"), found = try entry()
        let first = path.appendingPathComponent("first.bin")
        try FileManager.default.removeItem(at: first); try Data("replacement".utf8).write(to: first)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertEqual(try Data(contentsOf: first), Data("replacement".utf8))
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("second.bin")).count, 8192)
        XCTAssertEqual(try entry().status, .unverified)
    }
    func testSymlinkAndHardLinkCannotRedirectRecovery() throws {
        let path = try killFixture("filled"), found = try entry()
        let first = path.appendingPathComponent("first.bin")
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: root.appendingPathComponent("outside.txt"))
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        try FileManager.default.removeItem(at: first)
        try FileManager.default.linkItem(at: root.appendingPathComponent("outside.txt"), to: first)
        XCTAssertEqual(try entry().status, .unverified)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
    }
    func testAdditionalUnknownChildPreventsAllRecoveryDeletion() throws {
        let path = try killFixture("filled"), found = try entry()
        try Data("keep".utf8).write(to: path.appendingPathComponent("unknown.txt"))
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("first.bin")).count, 8192)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("unknown.txt")), Data("keep".utf8))
    }
    func testReplacedDirectoryAndManifestAreNeverDeleted() throws {
        let path = try killFixture("filled"), found = try entry()
        let relocated = root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: path, to: relocated)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("replacement".utf8).write(to: path.appendingPathComponent("keep.txt"))
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertEqual(try Data(contentsOf: relocated.appendingPathComponent("first.bin")).count, 8192)
        try FileManager.default.removeItem(at: path); try FileManager.default.moveItem(at: relocated, to: path)
        let contents = try Data(contentsOf: manifest(path))
        try FileManager.default.removeItem(at: manifest(path))
        try contents.write(to: manifest(path)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest(path).path)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertEqual(try entry().status, .unverified)
    }
    func testManifestChangeRequiresNewProofAndCannotGuessNames() throws {
        let path = try killFixture("filled"), found = try entry()
        try replaceManifest(path) { data in
            var lines: [Data] = data.split(separator: 10)
            guard case .header(let h) = try JSONDecoder().decode(WorkspaceRecord.self, from: lines[0]) else { throw WorkspaceRecoveryError.changed }
            lines[0] = try JSONEncoder().encode(WorkspaceRecord.header(.init(version: h.version, id: h.id, nonce: UUID(), createdAt: h.createdAt, filesystem: h.filesystem, directory: h.directory, manifest: h.manifest)))
            return lines.reduce(into: Data()) { $0.append($1); $0.append(10) }
        }
        let updated = try entry(); XCTAssertEqual(updated.status, .recoverable); XCTAssertNotEqual(updated.proof, found.proof)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("first.bin")).count, 8192)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: updated)
    }
    func testLegacyAndMissingManifestAreReportedWithoutDeletion() throws {
        let legacy = root.appendingPathComponent(CapacityVerifier.testDirectoryName)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: false)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("data.bin"))
        let candidate = root.appendingPathComponent(WorkspaceJournal.prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent(WorkspaceJournal.prefix + String(repeating: "a", count: 200)), withIntermediateDirectories: false)
        let found = try scan(); XCTAssertEqual(found.leftovers.count, 3); XCTAssertTrue(found.complete); try found.validate()
        XCTAssertTrue(found.leftovers.allSatisfy { $0.status == .unverified })
        for item in found.leftovers { XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: item)) }
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("data.bin")), Data("legacy".utf8))
    }
    func testManifestPermissionsAndOversizedFramingFailClosed() throws {
        let path = try killFixture("filled"), found = try entry()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: manifest(path).path)
        XCTAssertEqual(try entry().status, .unverified)
        XCTAssertThrowsError(try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest(path).path)
        try replaceManifest(path) { _ in Data(repeating: 32, count: WorkspaceJournal.maxRecordBytes + 1) + Data([10]) }
        XCTAssertEqual(try entry().status, .unverified)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("second.bin")).count, 8192)
    }
    func testMalformedDuplicatedAndForeignFilesystemRecordsFailClosed() throws {
        let path = try killFixture("filled"), original = try Data(contentsOf: manifest(path))
        var lines: [Data] = original.split(separator: 10)
        try replaceManifest(path) { _ in lines.reduce(into: Data()) { $0.append($1); $0.append(10) } + lines[1] + Data([10]) }
        XCTAssertEqual(try entry().status, .unverified)
        guard case .header(let h) = try JSONDecoder().decode(WorkspaceRecord.self, from: lines[0]) else { return XCTFail("header") }
        let foreign = MountedFilesystemIdentity(filesystemID: "wrong", mountedFrom: "wrong", mountedAt: "wrong", volumeUUID: "foreign")
        lines[0] = try JSONEncoder().encode(WorkspaceRecord.header(.init(version: 1, id: h.id, nonce: h.nonce, createdAt: h.createdAt, filesystem: foreign, directory: h.directory, manifest: h.manifest)))
        try replaceManifest(path) { _ in lines.reduce(into: Data()) { $0.append($1); $0.append(10) } }
        XCTAssertEqual(try entry().status, .unverified)
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("first.bin")).count, 8192)
    }
    func testScanCandidateBudgetReturnsPartialRatherThanClean() throws {
        for _ in 0...DiskWorkspaceRecovery.maximumWorkspaces {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(WorkspaceJournal.prefix + UUID().uuidString), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let found = try scan(); XCTAssertFalse(found.complete); XCTAssertEqual(found.leftovers.count, DiskWorkspaceRecovery.maximumWorkspaces)
        XCTAssertNotNil(found.diagnostic); try found.validate()
    }
    func testManifestWriteAndSyncFailuresNeverReturnWritableDescriptor() throws {
        var calls = 0, io = WorkspaceJournalIO()
        io.write = { fd, pointer, count in
            calls += 1
            if calls > 1 { errno = ENOSPC; return -1 }
            return Darwin.write(fd, pointer, count)
        }
        var workspace: DiskTestWorkspace? = try DiskTestWorkspace.fixture(at: root, journalIO: io)
        XCTAssertThrowsError(try workspace!.createFile("data.bin"))
        XCTAssertEqual(try Data(contentsOf: workspace!.directoryURL.appendingPathComponent("data.bin")).count, 0)
        try workspace!.cleanup(); workspace = nil
        var syncCalls = 0
        io = .init(); io.synchronize = { fd in syncCalls += 1; if syncCalls == 3 { errno = EIO; return -1 }; return fsync(fd) }
        workspace = try DiskTestWorkspace.fixture(at: root, journalIO: io)
        XCTAssertThrowsError(try workspace!.createFile("data.bin"))
        XCTAssertEqual(try Data(contentsOf: workspace!.directoryURL.appendingPathComponent("data.bin")).count, 0)
        try workspace!.cleanup(); workspace = nil
        XCTAssertTrue(try scan().leftovers.isEmpty)
    }
    func testFailedJournalInitializationDoesNotLeakOrDoubleCloseDescriptors() throws {
        func descriptors() -> Set<Int32> { Set((0..<1024).map(Int32.init).filter { fcntl($0, F_GETFD) >= 0 }) }
        let before = descriptors()
        var io = WorkspaceJournalIO(); io.synchronize = { _ in errno = EIO; return -1 }
        for _ in 0..<40 { XCTAssertThrowsError(try DiskTestWorkspace.fixture(at: root, journalIO: io)) }
        XCTAssertEqual(descriptors(), before)
        XCTAssertTrue(try scan().leftovers.isEmpty)
        let next = try DiskTestWorkspace.fixture(at: root)
        let fd = try next.createFile("works.bin"); XCTAssertEqual(fcntl(fd, F_GETFD) >= 0, true); close(fd)
        try next.cleanup()
    }
    func testMatchingVolumeUUIDAllowsFilesystemRemountMetadataToChange() throws {
        let path = try killFixture("filled")
        try replaceManifest(path) { original in
            var lines: [Data] = original.split(separator: 10)
            guard case .header(let h) = try JSONDecoder().decode(WorkspaceRecord.self, from: lines[0]) else { throw WorkspaceRecoveryError.changed }
            XCTAssertNotNil(h.filesystem.volumeUUID)
            let remounted = MountedFilesystemIdentity(filesystemID: "previous-fsid", mountedFrom: "/dev/disk999s1", mountedAt: "/Volumes/Previous", volumeUUID: h.filesystem.volumeUUID)
            lines[0] = try JSONEncoder().encode(WorkspaceRecord.header(.init(version: 1, id: h.id, nonce: h.nonce, createdAt: h.createdAt, filesystem: remounted, directory: h.directory, manifest: h.manifest)))
            return lines.reduce(into: Data()) { $0.append($1); $0.append(10) }
        }
        let found = try entry(); XCTAssertEqual(found.status, .recoverable)
        try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: found)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    func testManifestReplacementWhileLivePreventsEngineWritingData() throws {
        let workspace = try DiskTestWorkspace.fixture(at: root)
        let journal = manifest(workspace.directoryURL), saved = try Data(contentsOf: journal)
        try FileManager.default.removeItem(at: journal); try saved.write(to: journal)
        XCTAssertThrowsError(try workspace.createFile("data.bin"))
        XCTAssertEqual(try Data(contentsOf: workspace.directoryURL.appendingPathComponent("data.bin")).count, 0)
        XCTAssertThrowsError(try workspace.cleanup())
    }
    func testRenamedLiveWorkspaceRefusesFurtherCreation() throws {
        let workspace = try DiskTestWorkspace.fixture(at: root)
        let relocated = root.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: workspace.directoryURL, to: relocated)
        XCTAssertThrowsError(try workspace.createFile("data.bin"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: relocated.appendingPathComponent("data.bin").path))
    }
    func testCapacityFileBudgetRejectsRangeBeforeAnyTestDataWrite() throws {
        let volume = VolumeUsage(bsdName: "fixture", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "fixture")
        let config = CapacityVerifyConfig(reserveBytes: 1 << 20, fileSizeBytes: 4096, blockBytes: 4096,
                                          maxBytes: UInt64(DiskWorkspaceRecovery.maximumFiles + 1) * 4096)
        var writes = 0, io = CapacityFileIO(); io.write = { _, _, _, _ in writes += 1; return 0 }
        XCTAssertThrowsError(try CapacityVerifier(io: io).run(in: root, volume: volume, config: config)) {
            guard case BenchmarkError.invalidConfiguration = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(writes, 0); XCTAssertTrue(try scan().leftovers.isEmpty)
    }
    func testRecoveryReplyRejectsInvalidProofMetadataAndWrongOperation() throws {
        let path = try killFixture("filled"), found = try scan()
        let drive = DriveInfo(registryEntryID: 1, bsdName: "disk999999", model: "Fixture", serialNumber: nil, firmwareRevision: nil, sizeBytes: 1024, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
        let volume = VolumeUsage(bsdName: "fixture", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "fixture", writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        let request = HardwareRequest(operation: .workspaces(drive, volume: volume)), client = HardwareWorkerClient(executable: "/invalid")
        guard case .workspaces = try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, value: .workspaces(found))), for: request) else { return XCTFail("wrong reply") }
        let invalid = DiskWorkspaceScan(leftovers: [.init(name: path.lastPathComponent, path: path.path, status: .recoverable, bytes: 1, fileCount: 1, diagnostic: nil, proof: "wrong")], complete: true, diagnostic: nil, parentIdentity: found.parentIdentity)
        XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, value: .workspaces(invalid))), for: request))
        XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: request.id, value: .acknowledged)), for: request))
        let cleanup = HardwareRequest(operation: .cleanupWorkspace(drive, volume: volume, leftover: try entry(), lockToken: UUID()))
        XCTAssertThrowsError(try client.decode(JSONEncoder().encode(HardwareReply(id: cleanup.id, value: .workspaces(found))), for: cleanup))
    }
    func testActualWorkerRejectsUnboundCleanupAndArbitraryVolumeBeforeMutation() async throws {
        let path = try killFixture("filled"), leftover = try entry()
        let worker = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("mdrivehealth-worker")
        let client = HardwareWorkerClient(executable: worker.path)
        guard case .drives(let drives) = try await client.perform(.enumerate), let drive = drives.first(where: { !$0.isVirtual }) else {
            throw XCTSkip("No physical block-storage device on this host")
        }
        let fakeVolume = VolumeUsage(bsdName: "fixture", name: "Fixture", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40, sharedCapacityKey: "fixture")
        do { _ = try await client.perform(.cleanupWorkspace(drive, volume: fakeVolume, leftover: leftover, lockToken: UUID())); XCTFail("missing delegation must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Unsafe device-lock"), "\(error)") }
        do { _ = try await client.perform(.workspaces(drive, volume: fakeVolume)); XCTFail("an arbitrary directory is not a current drive volume") }
        catch { XCTAssertTrue(error.localizedDescription.contains("attachment changed"), "\(error)") }
        XCTAssertEqual(try Data(contentsOf: path.appendingPathComponent("first.bin")).count, 8192)
        XCTAssertEqual(try entry().status, .recoverable)
    }
}
