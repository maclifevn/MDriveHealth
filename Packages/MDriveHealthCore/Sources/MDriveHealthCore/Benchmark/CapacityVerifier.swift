/*
 * CapacityVerifier.swift — H2testw-style fake-capacity detection.
 *
 * Fake-capacity flash (a real community plague: "2 TB" USB sticks with 32 GB
 * of NAND that silently wrap writes) passes every SMART check and even short
 * benchmarks. The only reliable userspace test is H2testw's: fill the free
 * space with deterministic pseudo-random data, read it back, and verify —
 * on a wrapped controller writes may corrupt earlier data. A mismatch is
 * evidence of corruption, not a measurement of physical NAND capacity.
 *
 * Same I/O discipline as DiskBenchmarkEngine: F_NOCACHE, page-aligned
 * buffers/offsets, files capped at 1 GiB (FAT32-safe), owned-file cleanup.
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public struct CapacityVerifyConfig: Sendable, Hashable, Codable {
    /// Free space to leave untouched (the OS misbehaves at 0 B free).
    public var reserveBytes: UInt64
    /// Size of each test file (multiple files: FAT32 caps files at 4 GiB − 1).
    public var fileSizeBytes: UInt64
    /// I/O block size — also the verification granularity.
    public var blockBytes: Int
    /// Optional cap on how much to test (nil = fill all free space). Lets
    /// tests and impatient users bound the run.
    public var maxBytes: UInt64?
    public var dataRiskAcknowledged: Bool
    public var sharedCapacityRiskAcknowledged: Bool

    public init(reserveBytes: UInt64 = 512 << 20,
                fileSizeBytes: UInt64 = 1 << 30,
                blockBytes: Int = 4 << 20,
                maxBytes: UInt64? = nil,
                dataRiskAcknowledged: Bool = false,
                sharedCapacityRiskAcknowledged: Bool = false) {
        self.reserveBytes = reserveBytes
        self.fileSizeBytes = fileSizeBytes
        self.blockBytes = blockBytes
        self.maxBytes = maxBytes
        self.dataRiskAcknowledged = dataRiskAcknowledged
        self.sharedCapacityRiskAcknowledged = sharedCapacityRiskAcknowledged
    }

    public func validate() throws {
        guard blockBytes > 0, blockBytes <= 8 << 20, blockBytes % BenchmarkConfig.pageSize == 0 else {
            throw BenchmarkError.invalidConfiguration(
                "blockBytes must be a multiple of 4096 between 4 KiB and 8 MiB")
        }
        guard fileSizeBytes > 0, fileSizeBytes % UInt64(blockBytes) == 0,
              fileSizeBytes < (1 << 32) else {
            throw BenchmarkError.invalidConfiguration(
                "fileSizeBytes must be a multiple of blockBytes and under 4 GiB")
        }
        guard !reserveBytes.addingReportingOverflow(UInt64(blockBytes)).overflow else {
            throw BenchmarkError.invalidConfiguration("reserveBytes + blockBytes overflows")
        }
        // A cap below one block floors the target to zero — run() would then
        // write nothing and report a false "genuine" verdict.
        if let cap = maxBytes {
            guard cap >= UInt64(blockBytes) else {
                throw BenchmarkError.invalidConfiguration(
                    "maxBytes must be at least one block")
            }
        }
    }
}

public enum CapacityVerifyPhase: String, Sendable, Codable {
    case filling, verifying
}

public struct CapacityVerifyProgress: Sendable, Codable {
    public let phase: CapacityVerifyPhase
    public let fractionCompleted: Double
    public let bytesProcessed: UInt64
    public let totalBytes: UInt64
    public let instantaneousBytesPerSecond: Double
}

public enum CapacityVerifyInterruption: String, Sendable, Hashable, Codable {
    case spaceExhausted, shortWrite, writeFailed, readFailed, cacheUnavailable, flushFailed
}

public struct CapacityVerifyResult: Sendable, Hashable, Codable {
    public enum Verdict: String, Sendable, Hashable, Codable {
        /// Only the requested test range was written and read back intact.
        case passedTestedRange
        /// At least one tested byte differed. This does not establish fraud.
        case dataCorrupted
        /// The requested test range did not complete reliably.
        case inconclusive
    }

    public let capturedAt: Date
    public let volumeName: String
    public let mountPoint: String
    public let bytesRequested: UInt64
    public let bytesWritten: UInt64
    public let bytesVerifiedOK: UInt64
    /// Logical offset in test data, never a physical-capacity estimate.
    public let firstCorruptionOffset: UInt64?
    public let corruptedBlocks: Int
    public let writeBytesPerSec: Double
    public let readBytesPerSec: Double
    public let verdict: Verdict
    public let interruption: CapacityVerifyInterruption?

    public var summaryTitle: String {
        switch verdict {
        case .passedTestedRange:
            return String(localized: "capacity.result.passed.title", defaultValue: "PHẦN ĐÃ KIỂM TRA KHỚP DỮ LIỆU", bundle: .module)
        case .dataCorrupted:
            return String(localized: "capacity.result.corrupt.title", defaultValue: "PHÁT HIỆN DỮ LIỆU KIỂM TRA BỊ HỎNG", bundle: .module)
        case .inconclusive:
            return String(localized: "capacity.result.inconclusive.title", defaultValue: "CHƯA KẾT LUẬN ĐƯỢC", bundle: .module)
        }
    }

    public var summaryDetail: String {
        let written = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytesWritten), countStyle: .file)
        let verified = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytesVerifiedOK), countStyle: .file)
        let requested = ByteCountFormatter.string(fromByteCount: Int64(clamping: bytesRequested), countStyle: .file)
        let scope = String(localized: "capacity.result.scope", defaultValue: "Đã ghi \(written), xác minh khớp \(verified), yêu cầu \(requested). Kết quả chỉ áp dụng cho dữ liệu đã kiểm tra, không chứng nhận toàn bộ dung lượng ổ.", bundle: .module)
        switch verdict {
        case .passedTestedRange: return scope
        case .dataCorrupted:
            return scope + " " + String(localized: "capacity.result.corrupt.reason", defaultValue: "Có dữ liệu đọc lại khác dữ liệu đã ghi. Nguyên nhân có thể là media, kết nối hoặc firmware khai khống; chưa xác định được dung lượng vật lý thật. Không dùng ổ này cho dữ liệu quan trọng trước khi kiểm tra thêm.", bundle: .module)
        case .inconclusive:
            return scope + " " + String(localized: "capacity.result.incomplete.reason", defaultValue: "Phiên kiểm tra chưa hoàn tất tin cậy do lỗi đọc/ghi, hết chỗ trống hoặc không xác nhận được cache/flush.", bundle: .module)
        }
    }

    public var symbolName: String {
        switch verdict {
        case .passedTestedRange: return "checkmark.seal.fill"
        case .dataCorrupted: return "xmark.seal.fill"
        case .inconclusive: return "questionmark.diamond.fill"
        }
    }
}

/// Fault-injection seam for real I/O failure paths, never supplied by the UI.
struct CapacityFileIO {
    var write: (Int32, UnsafeRawPointer, Int, off_t) -> Int = { pwrite($0, $1, $2, $3) }
    var read: (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = { pread($0, $1, $2, $3) }
    var noCache: (Int32) -> Int32 = { fcntl($0, F_NOCACHE, 1) }
    var flush: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC, 0) }
}

public final class CapacityVerifier: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (CapacityVerifyProgress) -> Void

    public static let testDirectoryName = ".com.maclife.mdrivehealth.capacitytest"

    private static let runLock = NSLock()

    private let io: CapacityFileIO
    public init() { io = CapacityFileIO() }
    init(io: CapacityFileIO) { self.io = io }

    /// Legacy path only, for identifying old leftovers. New runs use unique
    /// owned workspaces. Do not automatically remove legacy directories.
    public static func testDirectoryURL(for volume: VolumeUsage) -> URL {
        if volume.mountPoint == "/" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(testDirectoryName, isDirectory: true)
        }
        return URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
            .appendingPathComponent(testDirectoryName, isDirectory: true)
    }

    /// Blocking. The caller must acknowledge risk after selecting a volume.
    /// Boot-volume fill tests are disallowed. Shared APFS space needs a second
    /// acknowledgement because other volumes consume the same free blocks.
    public func run(volume: VolumeUsage,
                    config: CapacityVerifyConfig = CapacityVerifyConfig(),
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping ProgressHandler = { _ in }) throws -> CapacityVerifyResult {
        try run(volume: volume, config: config, isCancelled: isCancelled, progress: progress,
                measurementID: UUID(), cleanupProgress: { _ in })
    }
    public func run(volume: VolumeUsage, config: CapacityVerifyConfig,
                    isCancelled: @escaping @Sendable () -> Bool, progress: @escaping ProgressHandler,
                    measurementID: UUID, cleanupProgress: @escaping @Sendable (Int) -> Void) throws -> CapacityVerifyResult {
        try config.validate()
        if isCancelled() { throw BenchmarkError.cancelled }
        guard volume.mountPoint != "/" else { throw BenchmarkError.unsafeCapacityTarget }
        guard config.dataRiskAcknowledged,
              !volume.sharesCapacity || config.sharedCapacityRiskAcknowledged else {
            throw BenchmarkError.capacityRiskNotAcknowledged
        }
        let workspace = try DiskTestWorkspace.open(volume: volume, sessionID: measurementID, cleanupProgress: cleanupProgress)
        return try workspace.withCleanup {
            try run(workspace: workspace, volume: volume, config: config,
                    isCancelled: isCancelled, progress: progress)
        }
    }

    /// Tests explicitly opt into a directory fixture; missing directories are
    /// never created. This cannot be reached from app or CLI entry points.
    func run(in directory: URL, volume: VolumeUsage, config: CapacityVerifyConfig,
             isCancelled: @escaping @Sendable () -> Bool = { false },
             progress: @escaping ProgressHandler = { _ in },
             measurementID: UUID = UUID(), cleanupProgress: @escaping @Sendable (Int) -> Void = { _ in }) throws -> CapacityVerifyResult {
        try config.validate()
        if isCancelled() { throw BenchmarkError.cancelled }
        let workspace = try DiskTestWorkspace.fixture(at: directory, sessionID: measurementID, cleanupProgress: cleanupProgress)
        return try workspace.withCleanup {
            try run(workspace: workspace, volume: volume, config: config,
                    isCancelled: isCancelled, progress: progress)
        }
    }

    private func run(workspace: DiskTestWorkspace, volume: VolumeUsage,
                     config: CapacityVerifyConfig, isCancelled: @escaping @Sendable () -> Bool,
                     progress: @escaping ProgressHandler) throws -> CapacityVerifyResult {
        guard Self.runLock.try() else { throw BenchmarkError.alreadyRunning }
        defer { Self.runLock.unlock() }
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Capacity verification")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let free = try workspace.freeBytes()
        let required = config.reserveBytes + UInt64(config.blockBytes) // validated, no overflow
        guard free >= required else {
            throw BenchmarkError.insufficientFreeSpace(requiredBytes: required, availableBytes: free)
        }
        var target = free - config.reserveBytes
        if let cap = config.maxBytes { target = min(target, cap) }
        target -= target % UInt64(config.blockBytes)
        guard target >= UInt64(config.blockBytes) else {
            throw BenchmarkError.insufficientFreeSpace(requiredBytes: required, availableBytes: free)
        }
        let fileCount = target / config.fileSizeBytes + (target % config.fileSizeBytes == 0 ? 0 : 1)
        guard fileCount <= UInt64(DiskWorkspaceRecovery.maximumFiles) else {
            throw BenchmarkError.invalidConfiguration("Requested range exceeds the temporary file ownership budget; increase fileSizeBytes")
        }
        let seed = UInt64.random(in: .min ... .max)
        let capturedAt = Date()
        let written = try fill(files: workspace, target: target, seed: seed, config: config,
                               isCancelled: isCancelled, progress: progress)
        let verified = try verify(files: workspace, expectedBytes: written.bytes, seed: seed,
                                  config: config, isCancelled: isCancelled, progress: progress)
        let interruption = written.interruption ?? verified.interruption
        let verdict: CapacityVerifyResult.Verdict
        if verified.firstCorruption != nil {
            verdict = .dataCorrupted
        } else if interruption != nil || written.bytes != target || verified.okBytes != target || target == 0 {
            verdict = .inconclusive
        } else {
            verdict = .passedTestedRange
        }
        return CapacityVerifyResult(capturedAt: capturedAt, volumeName: volume.name,
                                    mountPoint: volume.mountPoint, bytesRequested: target,
                                    bytesWritten: written.bytes, bytesVerifiedOK: verified.okBytes,
                                    firstCorruptionOffset: verified.firstCorruption,
                                    corruptedBlocks: verified.corruptedBlocks,
                                    writeBytesPerSec: written.bytesPerSec,
                                    readBytesPerSec: verified.bytesPerSec, verdict: verdict,
                                    interruption: interruption)
    }

    // MARK: - Pattern generation (SplitMix64 — deterministic per block)

    /// Fills `buffer` with the keyed pattern for a global block index.
    /// Deterministic: verification regenerates the exact bytes from
    /// (seed, blockIndex) without storing anything.
    static func fillPattern(buffer: UnsafeMutableRawPointer, byteCount: Int,
                            seed: UInt64, blockIndex: UInt64) {
        var state = seed ^ (blockIndex &* 0x9E37_79B9_7F4A_7C15)
        let words = buffer.bindMemory(to: UInt64.self, capacity: byteCount / 8)
        for i in 0..<(byteCount / 8) {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            words[i] = z ^ (z >> 31)
        }
    }

    // MARK: - Phases

    // Internal (not private): tests drive fill/verify separately so they can
    // corrupt a file in between and prove detection works.
    struct FillOutcome {
        let bytes: UInt64
        let bytesPerSec: Double
        let interruption: CapacityVerifyInterruption?
    }
    struct VerifyOutcome {
        let okBytes: UInt64
        let firstCorruption: UInt64?
        let corruptedBlocks: Int
        /// Read failed mid-verify (fake drives often EIO past the wrap
        /// point) — verification stopped early but collected evidence stands.
        var readErrorEncountered: Bool { interruption != nil }
        let interruption: CapacityVerifyInterruption?
        let bytesPerSec: Double
    }

    func fill(directory: URL, target: UInt64, seed: UInt64, config: CapacityVerifyConfig,
              isCancelled: @Sendable () -> Bool, progress: ProgressHandler) throws -> FillOutcome {
        try config.validate()
        let files = try DiskTestWorkspace.fixture(at: directory, createSession: false)
        return try fill(files: files, target: target, seed: seed, config: config,
                        isCancelled: isCancelled, progress: progress)
    }

    func verify(directory: URL, expectedBytes: UInt64, seed: UInt64, config: CapacityVerifyConfig,
                isCancelled: @Sendable () -> Bool, progress: ProgressHandler) throws -> VerifyOutcome {
        try config.validate()
        let files = try DiskTestWorkspace.fixture(at: directory, createSession: false)
        return try verify(files: files, expectedBytes: expectedBytes, seed: seed, config: config,
                          isCancelled: isCancelled, progress: progress)
    }

    private func fill(files: DiskTestWorkspace, target: UInt64, seed: UInt64,
              config: CapacityVerifyConfig,
              isCancelled: @Sendable () -> Bool,
              progress: ProgressHandler) throws -> FillOutcome {
        let block = config.blockBytes
        var raw: UnsafeMutableRawPointer?
        let allocError = posix_memalign(&raw, BenchmarkConfig.pageSize, block)
        guard allocError == 0, let buffer = raw else {
            throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: allocError)
        }
        defer { free(buffer) }

        let clock = ContinuousClock()
        let start = clock.now
        var lastEmit = start
        var lastBytes: UInt64 = 0
        var globalBlock: UInt64 = 0
        var written: UInt64 = 0
        var fileIndex = 0

        while written < target {
            let fd = try files.createFile(String(format: "%04d.bin", fileIndex))
            defer { close(fd) }
            guard io.noCache(fd) == 0 else {
                return FillOutcome(bytes: written, bytesPerSec: rate(bytes: written, since: start, clock: clock),
                                   interruption: .cacheUnavailable)
            }
            var fileBytes: UInt64 = 0
            while fileBytes < config.fileSizeBytes, written < target {
                if isCancelled() { throw BenchmarkError.cancelled }
                try files.validateFilesystem()
                Self.fillPattern(buffer: buffer, byteCount: block, seed: seed, blockIndex: globalBlock)
                var n: Int
                repeat {
                    if isCancelled() { throw BenchmarkError.cancelled }
                    n = io.write(fd, buffer, block, off_t(fileBytes))
                } while n == -1 && errno == EINTR
                guard n == block else {
                    let errorCode = errno
                    if n > 0 && n < block { written += UInt64(n) }
                    let interruption: CapacityVerifyInterruption = n == -1 && errorCode == ENOSPC
                        ? .spaceExhausted : (n >= 0 && n < block ? .shortWrite : .writeFailed)
                    // Flush even the partial final file, but never turn it into
                    // a pass for the original requested range.
                    _ = io.flush(fd)
                    return FillOutcome(bytes: written, bytesPerSec: rate(bytes: written, since: start, clock: clock),
                                       interruption: interruption)
                }
                fileBytes += UInt64(block)
                written += UInt64(block)
                globalBlock += 1

                let now = clock.now
                if seconds(lastEmit.duration(to: now)) >= 0.2 {
                    let instant = Double(written - lastBytes)
                        / seconds(lastEmit.duration(to: now))
                    progress(CapacityVerifyProgress(
                        phase: .filling,
                        fractionCompleted: Double(written) / Double(max(target, 1)),
                        bytesProcessed: written, totalBytes: target,
                        instantaneousBytesPerSecond: instant))
                    lastEmit = now
                    lastBytes = written
                }
            }
            guard io.flush(fd) == 0 else {
                return FillOutcome(bytes: written, bytesPerSec: rate(bytes: written, since: start, clock: clock),
                                   interruption: .flushFailed)
            }
            fileIndex += 1
        }
        return FillOutcome(bytes: written,
                           bytesPerSec: rate(bytes: written, since: start, clock: clock), interruption: nil)
    }

    private func verify(files: DiskTestWorkspace, expectedBytes: UInt64, seed: UInt64,
                config: CapacityVerifyConfig,
                isCancelled: @Sendable () -> Bool,
                progress: ProgressHandler) throws -> VerifyOutcome {
        let block = config.blockBytes
        var rawRead: UnsafeMutableRawPointer?
        let e1 = posix_memalign(&rawRead, BenchmarkConfig.pageSize, block)
        guard e1 == 0, let readBuffer = rawRead else {
            throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: e1)
        }
        defer { free(readBuffer) }
        var rawExpect: UnsafeMutableRawPointer?
        let e2 = posix_memalign(&rawExpect, BenchmarkConfig.pageSize, block)
        guard e2 == 0, let expectBuffer = rawExpect else {
            throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: e2)
        }
        defer { free(expectBuffer) }

        let clock = ContinuousClock()
        let start = clock.now
        var lastEmit = start
        var lastBytes: UInt64 = 0
        var processed: UInt64 = 0
        var okBytes: UInt64 = 0
        var firstCorruption: UInt64?
        var corruptedBlocks = 0
        var globalBlock: UInt64 = 0
        var fileIndex = 0

        while processed < expectedBytes {
            let fd: Int32
            do { fd = try files.openFile(String(format: "%04d.bin", fileIndex)) }
            catch {
                return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                                     corruptedBlocks: corruptedBlocks, interruption: .readFailed,
                                     bytesPerSec: rate(bytes: processed, since: start, clock: clock))
            }
            defer { close(fd) }
            guard io.noCache(fd) == 0 else {
                return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                                     corruptedBlocks: corruptedBlocks, interruption: .cacheUnavailable,
                                     bytesPerSec: rate(bytes: processed, since: start, clock: clock))
            }
            var fileBytes: UInt64 = 0
            while fileBytes < config.fileSizeBytes, processed < expectedBytes {
                if isCancelled() { throw BenchmarkError.cancelled }
                try files.validateFilesystem()
                let length = Int(min(UInt64(block), expectedBytes - processed))
                var n: Int
                repeat {
                    if isCancelled() { throw BenchmarkError.cancelled }
                    n = io.read(fd, readBuffer, length, off_t(fileBytes))
                } while n == -1 && errno == EINTR
                guard n == length else {
                    return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                                         corruptedBlocks: corruptedBlocks, interruption: .readFailed,
                                         bytesPerSec: rate(bytes: processed, since: start, clock: clock))
                }
                Self.fillPattern(buffer: expectBuffer, byteCount: block,
                                 seed: seed, blockIndex: globalBlock)
                if memcmp(readBuffer, expectBuffer, length) == 0 {
                    okBytes += UInt64(length)
                } else {
                    corruptedBlocks += 1
                    if firstCorruption == nil {
                        firstCorruption = processed
                    }
                }
                fileBytes += UInt64(length)
                processed += UInt64(length)
                globalBlock += 1

                let now = clock.now
                if seconds(lastEmit.duration(to: now)) >= 0.2 {
                    let instant = Double(processed - lastBytes)
                        / seconds(lastEmit.duration(to: now))
                    progress(CapacityVerifyProgress(
                        phase: .verifying,
                        fractionCompleted: Double(processed) / Double(max(expectedBytes, 1)),
                        bytesProcessed: processed, totalBytes: expectedBytes,
                        instantaneousBytesPerSecond: instant))
                    lastEmit = now
                    lastBytes = processed
                }
            }
            fileIndex += 1
        }
        return VerifyOutcome(okBytes: okBytes, firstCorruption: firstCorruption,
                             corruptedBlocks: corruptedBlocks,
                             interruption: nil,
                             bytesPerSec: rate(bytes: processed, since: start, clock: clock))
    }

    // MARK: - Helpers

    private func rate(bytes: UInt64, since start: ContinuousClock.Instant,
                      clock: ContinuousClock) -> Double {
        let elapsed = seconds(start.duration(to: clock.now))
        return elapsed > 0 ? Double(bytes) / elapsed : 0
    }

    private func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
