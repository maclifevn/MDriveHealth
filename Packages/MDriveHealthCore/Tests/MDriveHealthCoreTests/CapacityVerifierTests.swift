/*
 * CapacityVerifierTests.swift — fake-capacity detection engine.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class CapacityVerifierTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-captest-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Tiny geometry so tests run in milliseconds: 4 KiB blocks, 16 KiB files.
    private var tinyConfig: CapacityVerifyConfig {
        CapacityVerifyConfig(reserveBytes: 0, fileSizeBytes: 16 << 10,
                             blockBytes: 4 << 10, maxBytes: nil)
    }

    func testFillPatternIsDeterministicAndBlockUnique() {
        let size = 4096
        let a = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        let b = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        defer { a.deallocate(); b.deallocate() }

        CapacityVerifier.fillPattern(buffer: a, byteCount: size, seed: 7, blockIndex: 3)
        CapacityVerifier.fillPattern(buffer: b, byteCount: size, seed: 7, blockIndex: 3)
        XCTAssertEqual(memcmp(a, b, size), 0, "same seed+index → same bytes")

        CapacityVerifier.fillPattern(buffer: b, byteCount: size, seed: 7, blockIndex: 4)
        XCTAssertNotEqual(memcmp(a, b, size), 0, "different block → different bytes")

        CapacityVerifier.fillPattern(buffer: b, byteCount: size, seed: 8, blockIndex: 3)
        XCTAssertNotEqual(memcmp(a, b, size), 0, "different seed → different bytes")
    }

    func testFillThenVerifyIntactDataIsGenuine() throws {
        let verifier = CapacityVerifier()
        let target: UInt64 = 48 << 10   // 12 blocks across 3 files
        let written = try verifier.fill(directory: directory, target: target, seed: 42,
                                        config: tinyConfig, isCancelled: { false },
                                        progress: { _ in })
        XCTAssertEqual(written.bytes, target)

        let outcome = try verifier.verify(directory: directory, expectedBytes: written.bytes,
                                          seed: 42, config: tinyConfig,
                                          isCancelled: { false }, progress: { _ in })
        XCTAssertNil(outcome.firstCorruption)
        XCTAssertEqual(outcome.corruptedBlocks, 0)
        XCTAssertEqual(outcome.okBytes, target)
    }

    func testCorruptionIsDetectedAtTheRightOffset() throws {
        let verifier = CapacityVerifier()
        let target: UInt64 = 48 << 10
        _ = try verifier.fill(directory: directory, target: target, seed: 42,
                              config: tinyConfig, isCancelled: { false },
                              progress: { _ in })

        // Corrupt one byte in the SECOND block of file 0001 — global block
        // index 5 (file 0 holds blocks 0-3), global offset 5 * 4096.
        let victim = directory.appendingPathComponent("0001.bin")
        let handle = try FileHandle(forWritingTo: victim)
        try handle.seek(toOffset: 4096 + 100)
        try handle.write(contentsOf: Data([0xAB]))
        try handle.close()

        let outcome = try verifier.verify(directory: directory, expectedBytes: target,
                                          seed: 42, config: tinyConfig,
                                          isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(outcome.corruptedBlocks, 1)
        XCTAssertEqual(outcome.firstCorruption, 5 * 4096)
        XCTAssertEqual(outcome.okBytes, target - 4096)
    }

    func testWrappedControllerSimulationDetectsDataCorruption() throws {
        // Simulate a fake drive that wraps writes: after filling, overwrite
        // the LAST file with the content pattern of the FIRST blocks (as a
        // wrapping controller would leave behind).
        let verifier = CapacityVerifier()
        let target: UInt64 = 64 << 10   // 16 blocks, 4 files
        _ = try verifier.fill(directory: directory, target: target, seed: 9,
                              config: tinyConfig, isCancelled: { false },
                              progress: { _ in })

        let size = 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 4096)
        defer { buffer.deallocate() }
        var replayed = Data()
        for block in 0..<4 {   // blocks 0-3 replayed where 12-15 should be
            CapacityVerifier.fillPattern(buffer: buffer, byteCount: size,
                                         seed: 9, blockIndex: UInt64(block))
            replayed.append(Data(bytes: buffer, count: size))
        }
        try replayed.write(to: directory.appendingPathComponent("0003.bin"))

        let outcome = try verifier.verify(directory: directory, expectedBytes: target,
                                          seed: 9, config: tinyConfig,
                                          isCancelled: { false }, progress: { _ in })
        XCTAssertEqual(outcome.firstCorruption, 12 * 4096,
                       "corruption starts exactly where the 'real capacity' ends")
        XCTAssertEqual(outcome.corruptedBlocks, 4)
    }

    func testEndToEndFixtureReportsOnlyTestedRange() throws {
        let volume = VolumeUsage(bsdName: "disk9s9", name: "Temp",
                                 mountPoint: directory.path,
                                 totalBytes: 1 << 40, availableBytes: 1 << 40,
                                 sharedCapacityKey: "disk9")
        var config = tinyConfig
        config.maxBytes = 64 << 10
        config.reserveBytes = 1 << 20
        let phases = CollectedPhases()

        let result: CapacityVerifyResult
        result = try CapacityVerifier().run(in: directory, volume: volume, config: config,
                                            isCancelled: { false },
                                            progress: { phases.record($0.phase) })
        XCTAssertEqual(result.verdict, .passedTestedRange)
        XCTAssertEqual(result.bytesRequested, 64 << 10)
        XCTAssertEqual(result.bytesWritten, 64 << 10)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancellationCleansUpViaRun() throws {
        let volume = VolumeUsage(bsdName: "disk9s9", name: "Temp",
                                 mountPoint: directory.path,
                                 totalBytes: 1 << 40, availableBytes: 1 << 40,
                                 sharedCapacityKey: "disk9")
        var config = tinyConfig
        config.maxBytes = 256 << 10
        config.reserveBytes = 1 << 20
        let counter = Counter()

        XCTAssertThrowsError(
            try CapacityVerifier().run(in: directory, volume: volume, config: config,
                                       isCancelled: { counter.bump() > 3 },
                                       progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? BenchmarkError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: CapacityVerifier.testDirectoryURL(for: volume).path))
    }
    func testMissingFileDuringVerifyIsInconclusiveNotError() throws {
        let verifier = CapacityVerifier()
        let target: UInt64 = 48 << 10
        _ = try verifier.fill(directory: directory, target: target, seed: 5,
                              config: tinyConfig, isCancelled: { false },
                              progress: { _ in })
        // Simulate a drive erroring past some point: remove the middle file.
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent("0001.bin"))

        let outcome = try verifier.verify(directory: directory, expectedBytes: target,
                                          seed: 5, config: tinyConfig,
                                          isCancelled: { false }, progress: { _ in })
        XCTAssertTrue(outcome.readErrorEncountered,
                      "read failure must be reported, not thrown")
        XCTAssertNil(outcome.firstCorruption)
        XCTAssertEqual(outcome.okBytes, 16 << 10, "file 0000 verified before the failure")
    }

}

private final class CollectedPhases: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: Set<CapacityVerifyPhase> = []
    var phases: Set<CapacityVerifyPhase> { lock.lock(); defer { lock.unlock() }; return _phases }
    func record(_ p: CapacityVerifyPhase) { lock.lock(); _phases.insert(p); lock.unlock() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
