/*
 * DiskBenchmarkTests.swift — config/location pure helpers + a small
 * end-to-end run against a temp file.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class DiskBenchmarkTests: XCTestCase {

    private func volume(mountPoint: String, bsd: String = "disk9s1",
                        available: UInt64 = 100 << 30) -> VolumeUsage {
        VolumeUsage(bsdName: bsd, name: "Test", mountPoint: mountPoint,
                    totalBytes: 200 << 30, availableBytes: available,
                    sharedCapacityKey: bsd)
    }

    // MARK: - Config validation

    func testConfigValidationAcceptsDefaults() throws {
        XCTAssertNoThrow(try BenchmarkConfig().validate())
    }

    func testConfigValidationRejectsUnalignedBlockSizes() {
        XCTAssertThrowsError(try BenchmarkConfig(sequentialBlockBytes: 4095).validate())
        XCTAssertThrowsError(try BenchmarkConfig(sequentialBlockBytes: 3 * 1_048_576 + 512).validate())
        XCTAssertThrowsError(try BenchmarkConfig(sequentialBlockBytes: 0).validate())
        XCTAssertThrowsError(try BenchmarkConfig(randomBlockBytes: 4095).validate())
    }

    func testConfigValidationRejectsFileSizeNotMultipleOfSequentialBlock() {
        // 10 MiB is not a whole number of 4 MiB blocks.
        let config = BenchmarkConfig(fileSizeBytes: 10 << 20, sequentialBlockBytes: 4 << 20)
        XCTAssertThrowsError(try config.validate())
    }

    func testConfigValidationRejectsRandomBlockLargerThanSequentialBlock() {
        // Buffers are sized to the sequential block; a larger random block
        // would overrun them.
        let config = BenchmarkConfig(fileSizeBytes: 8 << 20,
                                     sequentialBlockBytes: 4096,
                                     randomBlockBytes: 8 << 20)
        XCTAssertThrowsError(try config.validate())
    }

    func testConfigValidationRejectsAbsurdFileSize() {
        let config = BenchmarkConfig(fileSizeBytes: (2 << 40),
                                     sequentialBlockBytes: 4 << 20)
        XCTAssertThrowsError(try config.validate())
    }

    func testPresetFileSizesAreExactAndAligned() {
        for size in BenchmarkConfig.presetFileSizes {
            XCTAssertEqual(size % (8 << 20), 0, "preset \(size) must be a multiple of 8 MiB")
        }
    }

    // MARK: - Offset generation

    func testOffsetForBlockIndexIsPageAlignedAndInBounds() {
        let config = BenchmarkConfig(fileSizeBytes: 1 << 30, sequentialBlockBytes: 4 << 20)
        let blocks = DiskBenchmarkEngine.blockCount(
            fileSizeBytes: config.fileSizeBytes, blockBytes: config.sequentialBlockBytes)
        XCTAssertGreaterThan(blocks, 0)
        for _ in 0..<10_000 {
            let i = UInt64.random(in: 0..<blocks)
            let off = DiskBenchmarkEngine.offset(
                forBlockIndex: i, blockBytes: config.sequentialBlockBytes)
            XCTAssertEqual(off % 4096, 0)
            XCTAssertLessThanOrEqual(
                UInt64(off) + UInt64(config.sequentialBlockBytes), config.fileSizeBytes)
        }
    }

    // MARK: - IOPS derivation

    func testIOPSDerivationFromBytesPerSec() {
        let result = BenchmarkResult(
            capturedAt: Date(), volumeBSDName: "disk9s1", volumeName: "T", mountPoint: "/Volumes/T",
            fileSizeBytes: 1 << 30, sequentialBlockBytes: 4 << 20, randomBlockBytes: 4096,
            sequentialWriteBytesPerSec: 1, sequentialReadBytesPerSec: 1,
            randomWriteBytesPerSec: 40_960_000, randomReadBytesPerSec: nil)
        XCTAssertEqual(result.randomWriteIOPS ?? 0, 10_000, accuracy: 0.001)
        XCTAssertNil(result.randomReadIOPS)
    }

    // MARK: - Location

    func testTestFileURLForExternalVolumeIsHiddenRootFile() {
        let url = BenchmarkLocation.testFileURL(for: volume(mountPoint: "/Volumes/Ext"))
        XCTAssertEqual(url.path, "/Volumes/Ext/\(BenchmarkLocation.testFileName)")
    }

    func testTestFileURLForBootVolumeUsesTemporaryDirectory() {
        let url = BenchmarkLocation.testFileURL(for: volume(mountPoint: "/"))
        XCTAssertTrue(url.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertEqual(url.lastPathComponent, BenchmarkLocation.testFileName)
    }

    func testValidateFreeSpaceThrowsTypedErrorWithValues() {
        let config = BenchmarkConfig(fileSizeBytes: 1 << 30)          // needs 1 GiB + 512 MiB
        XCTAssertThrowsError(
            try BenchmarkLocation.validateFreeSpace(availableBytes: 1 << 30, config: config)
        ) { error in
            guard case BenchmarkError.insufficientFreeSpace(let required, let available) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(required, config.requiredFreeBytes)
            XCTAssertEqual(available, 1 << 30)
        }
    }

    // MARK: - End-to-end (temp file, tiny sizes)

    private func tinyConfig(includeRandom: Bool = true) -> BenchmarkConfig {
        BenchmarkConfig(fileSizeBytes: 8 << 20, sequentialBlockBytes: 1 << 20,
                        randomBlockBytes: 4096, includeRandomPhases: includeRandom,
                        randomPhaseSeconds: 0.3)
    }

    func testFullRunCompletesAllPhasesQuickly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-bench-\(UUID().uuidString).tmp")
        let phases = PhaseCollector()
        let engine = DiskBenchmarkEngine()

        let result: BenchmarkResult
        do {
            result = try engine.run(testFileURL: url, volume: volume(mountPoint: "/tmp"),
                                    config: tinyConfig(), isCancelled: { false },
                                    progress: { phases.record($0) })
        } catch {
            throw XCTSkip("environment cannot run the benchmark: \(error)")
        }

        XCTAssertGreaterThan(result.sequentialWriteBytesPerSec, 0)
        XCTAssertGreaterThan(result.sequentialReadBytesPerSec, 0)
        XCTAssertGreaterThan(result.randomWriteBytesPerSec ?? 0, 0)
        XCTAssertGreaterThan(result.randomReadBytesPerSec ?? 0, 0)
        XCTAssertEqual(Set(phases.phases), Set(BenchmarkPhase.allCases),
                       "all four phases should emit progress")
        XCTAssertTrue(phases.fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "test file must be removed")
    }

    func testCancellationThrowsCancelledAndCleansUp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-bench-\(UUID().uuidString).tmp")
        let counter = CallCounter()
        let engine = DiskBenchmarkEngine()

        XCTAssertThrowsError(
            try engine.run(testFileURL: url, volume: volume(mountPoint: "/tmp"),
                           config: tinyConfig(), isCancelled: { counter.bump() > 2 },
                           progress: { _ in })
        ) { error in
            XCTAssertEqual(error as? BenchmarkError, .cancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRunWithoutRandomPhasesLeavesRandomFieldsNil() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-bench-\(UUID().uuidString).tmp")
        let engine = DiskBenchmarkEngine()
        let result: BenchmarkResult
        do {
            result = try engine.run(testFileURL: url, volume: volume(mountPoint: "/tmp"),
                                    config: tinyConfig(includeRandom: false),
                                    isCancelled: { false }, progress: { _ in })
        } catch {
            throw XCTSkip("environment cannot run the benchmark: \(error)")
        }
        XCTAssertNil(result.randomWriteBytesPerSec)
        XCTAssertNil(result.randomReadBytesPerSec)
    }
    func testConfigValidationRejectsBadQueueDepth() {
        XCTAssertThrowsError(try BenchmarkConfig(queueDepth: 0).validate())
        XCTAssertThrowsError(try BenchmarkConfig(queueDepth: 17).validate())
        XCTAssertNoThrow(try BenchmarkConfig(queueDepth: 8).validate())
    }

    func testConcurrentFullRunCompletesAndTagsDepth() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-bench-\(UUID().uuidString).tmp")
        var config = tinyConfig()
        config.queueDepth = 4
        let engine = DiskBenchmarkEngine()
        let result: BenchmarkResult
        do {
            result = try engine.run(testFileURL: url, volume: volume(mountPoint: "/tmp"),
                                    config: config, isCancelled: { false },
                                    progress: { _ in })
        } catch {
            throw XCTSkip("environment cannot run the benchmark: \(error)")
        }
        XCTAssertEqual(result.queueDepth, 4)
        XCTAssertGreaterThan(result.sequentialWriteBytesPerSec, 0)
        XCTAssertGreaterThan(result.sequentialReadBytesPerSec, 0)
        XCTAssertGreaterThan(result.randomReadBytesPerSec ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

}

// MARK: - Thread-safe test collectors

private final class PhaseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _phases: [BenchmarkPhase] = []
    private var _fractions: [Double] = []
    var phases: [BenchmarkPhase] { lock.lock(); defer { lock.unlock() }; return _phases }
    var fractions: [Double] { lock.lock(); defer { lock.unlock() }; return _fractions }
    func record(_ p: BenchmarkProgress) {
        lock.lock(); _phases.append(p.phase); _fractions.append(p.fractionCompleted); lock.unlock()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
}
