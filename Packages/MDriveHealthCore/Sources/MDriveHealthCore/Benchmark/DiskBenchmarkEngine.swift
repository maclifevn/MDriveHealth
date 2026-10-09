/*
 * DiskBenchmarkEngine.swift — file-based sequential + random disk benchmark.
 *
 * Bypasses the unified buffer cache with F_NOCACHE and fully page-aligned
 * (buffer, offset, length) I/O — an unaligned F_NOCACHE request silently
 * reverts to cached I/O and would measure RAM. Blocking; call off the main
 * thread. The test file is removed on every exit path.
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public final class DiskBenchmarkEngine: @unchecked Sendable {
    public typealias ProgressHandler = @Sendable (BenchmarkProgress) -> Void

    /// Guards against two concurrent runs in one process (the app's state
    /// machine is the primary guard; this catches programmer error).
    private static let runLock = NSLock()

    public init() {}

    /// Runs the full benchmark on a mounted, writable volume. Blocking —
    /// call from a background task/thread. `progress` fires ~5 Hz on the
    /// calling thread. Throws `BenchmarkError`.
    public func run(volume: VolumeUsage,
                    config: BenchmarkConfig = BenchmarkConfig(),
                    isCancelled: @escaping @Sendable () -> Bool = { false },
                    progress: @escaping ProgressHandler = { _ in }) throws -> BenchmarkResult {
        try run(volume: volume, config: config, isCancelled: isCancelled, progress: progress,
                measurementID: UUID(), cleanupProgress: { _ in })
    }
    public func run(volume: VolumeUsage, config: BenchmarkConfig,
                    isCancelled: @escaping @Sendable () -> Bool, progress: @escaping ProgressHandler,
                    measurementID: UUID, cleanupProgress: @escaping @Sendable (Int) -> Void) throws -> BenchmarkResult {
        try config.validate()
        if isCancelled() { throw BenchmarkError.cancelled }
        let workspace = try DiskTestWorkspace.open(volume: volume, sessionID: measurementID, cleanupProgress: cleanupProgress)
        return try workspace.withCleanup {
            try BenchmarkLocation.validate(workspace: workspace, config: config)
            let fd = try workspace.createFile("speed.bin")
            defer { close(fd) }
            return try run(fd: fd, volume: volume, config: config,
                           isCancelled: isCancelled, progress: progress)
        }
    }

    /// Owned small workspace for worker integration fixtures; not a production
    /// request operation and never selected by app/CLI inputs.
    func run(in directory: URL, volume: VolumeUsage, config: BenchmarkConfig,
             isCancelled: @escaping @Sendable () -> Bool, progress: @escaping ProgressHandler,
             measurementID: UUID, cleanupProgress: @escaping @Sendable (Int) -> Void) throws -> BenchmarkResult {
        try config.validate()
        let workspace = try DiskTestWorkspace.fixture(at: directory, sessionID: measurementID, cleanupProgress: cleanupProgress)
        return try workspace.withCleanup {
            let fd = try workspace.createFile("speed.bin"); defer { close(fd) }
            return try run(fd: fd, volume: volume, config: config, isCancelled: isCancelled, progress: progress)
        }
    }

    /// Test seam: skips preflight and benchmarks an explicit file URL.
    /// `volume` only labels the result.
    func run(testFileURL url: URL, volume: VolumeUsage, config: BenchmarkConfig,
             isCancelled: @escaping @Sendable () -> Bool,
             progress: @escaping ProgressHandler) throws -> BenchmarkResult {
        try config.validate()
        if isCancelled() { throw BenchmarkError.cancelled }
        let workspace = try DiskTestWorkspace.fixture(at: url.deletingLastPathComponent(), createSession: false)
        return try workspace.withCleanup {
            let fd = try workspace.createFile(url.lastPathComponent)
            defer { close(fd) }
            return try run(fd: fd, volume: volume, config: config,
                           isCancelled: isCancelled, progress: progress)
        }
    }

    private func run(fd: Int32, volume: VolumeUsage, config: BenchmarkConfig,
                     isCancelled: @escaping @Sendable () -> Bool,
                     progress: @escaping ProgressHandler) throws -> BenchmarkResult {
        guard Self.runLock.try() else { throw BenchmarkError.alreadyRunning }
        defer { Self.runLock.unlock() }

        try config.validate()
        let capturedAt = Date()
        let seqBlock = config.sequentialBlockBytes
        let fileSize = config.fileSizeBytes

        guard fcntl(fd, F_NOCACHE, 1) != -1 else {
            throw BenchmarkError.ioFailed(operation: "fcntl(F_NOCACHE)", errno: errno)
        }
        _ = fcntl(fd, F_RDAHEAD, 0)   // readahead is moot under F_NOCACHE; document intent

        try preallocate(fd: fd, fileSize: fileSize)

        // Incompressible buffers, page-aligned (an F_NOCACHE requirement),
        // rotated to defeat controller-side dedup/compression. With a queue
        // depth > 1 every worker needs its OWN buffer (pread writes into it).
        var buffers: [UnsafeMutableRawPointer] = []
        defer { buffers.forEach { free($0) } }
        for _ in 0..<max(4, config.queueDepth) {
            var raw: UnsafeMutableRawPointer?
            // posix_memalign returns its error code and does NOT set errno.
            let allocError = posix_memalign(&raw, BenchmarkConfig.pageSize, seqBlock)
            guard allocError == 0, let buf = raw else {
                throw BenchmarkError.ioFailed(operation: "posix_memalign", errno: allocError)
            }
            arc4random_buf(buf, seqBlock)
            buffers.append(buf)
        }

        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Disk speed benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        let depth = config.queueDepth

        // Phase 1 — sequential write (must run before any read: preallocated
        // but unwritten extents read back as synthesized zeros).
        let seqWrite = depth > 1
            ? try concurrentSequentialPhase(
                .sequentialWrite, fd: fd, buffers: buffers, blockBytes: seqBlock,
                fileSize: fileSize, depth: depth, isCancelled: isCancelled,
                progress: progress)
            : try sequentialPhase(
                .sequentialWrite, fd: fd, buffers: buffers, blockBytes: seqBlock,
                fileSize: fileSize, isCancelled: isCancelled, progress: progress)
        try fullSync(fd: fd)

        // Phase 2 — sequential read.
        let seqRead = depth > 1
            ? try concurrentSequentialPhase(
                .sequentialRead, fd: fd, buffers: buffers, blockBytes: seqBlock,
                fileSize: fileSize, depth: depth, isCancelled: isCancelled,
                progress: progress)
            : try sequentialPhase(
                .sequentialRead, fd: fd, buffers: buffers, blockBytes: seqBlock,
                fileSize: fileSize, isCancelled: isCancelled, progress: progress)

        var randWrite: Double?
        var randRead: Double?
        if config.includeRandomPhases {
            randWrite = depth > 1
                ? try concurrentRandomPhase(
                    .randomWrite, fd: fd, buffers: buffers,
                    blockBytes: config.randomBlockBytes, fileSize: fileSize,
                    seconds: config.randomPhaseSeconds, depth: depth,
                    isCancelled: isCancelled, progress: progress)
                : try randomPhase(
                    .randomWrite, fd: fd, buffers: buffers,
                    blockBytes: config.randomBlockBytes, fileSize: fileSize,
                    seconds: config.randomPhaseSeconds,
                    isCancelled: isCancelled, progress: progress)
            try fullSync(fd: fd)
            randRead = depth > 1
                ? try concurrentRandomPhase(
                    .randomRead, fd: fd, buffers: buffers,
                    blockBytes: config.randomBlockBytes, fileSize: fileSize,
                    seconds: config.randomPhaseSeconds, depth: depth,
                    isCancelled: isCancelled, progress: progress)
                : try randomPhase(
                    .randomRead, fd: fd, buffers: buffers,
                    blockBytes: config.randomBlockBytes, fileSize: fileSize,
                    seconds: config.randomPhaseSeconds,
                    isCancelled: isCancelled, progress: progress)
        }

        return BenchmarkResult(
            capturedAt: capturedAt,
            volumeBSDName: volume.bsdName, volumeName: volume.name,
            mountPoint: volume.mountPoint, fileSizeBytes: fileSize,
            sequentialBlockBytes: seqBlock, randomBlockBytes: config.randomBlockBytes,
            queueDepth: depth,
            sequentialWriteBytesPerSec: seqWrite, sequentialReadBytesPerSec: seqRead,
            randomWriteBytesPerSec: randWrite, randomReadBytesPerSec: randRead)
    }

    // MARK: - Pure helpers (unit-tested)

    static func blockCount(fileSizeBytes: UInt64, blockBytes: Int) -> UInt64 {
        blockBytes > 0 ? fileSizeBytes / UInt64(blockBytes) : 0
    }

    /// Always `index * blockBytes`, so every offset is blockBytes-aligned
    /// (hence 4 KiB-aligned) by construction.
    static func offset(forBlockIndex index: UInt64, blockBytes: Int) -> off_t {
        off_t(index &* UInt64(blockBytes))
    }

    // MARK: - Phases

    private func sequentialPhase(_ phase: BenchmarkPhase, fd: Int32,
                                 buffers: [UnsafeMutableRawPointer], blockBytes: Int,
                                 fileSize: UInt64, isCancelled: () -> Bool,
                                 progress: ProgressHandler) throws -> Double {
        let isWrite = (phase == .sequentialWrite)
        let total = Self.blockCount(fileSizeBytes: fileSize, blockBytes: blockBytes)
        let clock = ContinuousClock()
        let start = clock.now
        var emitter = ProgressEmitter(phase: phase, clock: clock)
        // force: the very first emission would otherwise be swallowed by the
        // 0.2 s rate gate, lagging the UI phase label by a tick.
        emitter.emit(fraction: 0, totalBytes: 0, progress: progress, force: true)

        for i in 0..<total {
            if isCancelled() { throw BenchmarkError.cancelled }
            let buffer = buffers[Int(i % 4)]
            let off = Self.offset(forBlockIndex: i, blockBytes: blockBytes)
            let n = isWrite
                ? pwrite(fd, buffer, blockBytes, off)
                : pread(fd, buffer, blockBytes, off)
            guard n != -1 else {
                // A volume filling up mid-run deserves the friendly message,
                // not a raw errno (preflight's free-space check is TOCTOU).
                if errno == ENOSPC { throw BenchmarkError.diskFull }
                throw BenchmarkError.ioFailed(operation: isWrite ? "pwrite" : "pread",
                                              errno: errno)
            }
            guard n == blockBytes else {
                throw BenchmarkError.shortIO(expectedBytes: blockBytes, actualBytes: n)
            }
            let done = (i &+ 1) &* UInt64(blockBytes)
            emitter.emit(fraction: Double(i &+ 1) / Double(total),
                         totalBytes: done, progress: progress)
        }
        let elapsed = seconds(start.duration(to: clock.now))
        emitter.emit(fraction: 1, totalBytes: fileSize, progress: progress, force: true)
        return elapsed > 0 ? Double(fileSize) / elapsed : 0
    }

    private func randomPhase(_ phase: BenchmarkPhase, fd: Int32,
                             buffers: [UnsafeMutableRawPointer], blockBytes: Int,
                             fileSize: UInt64, seconds budget: TimeInterval,
                             isCancelled: () -> Bool,
                             progress: ProgressHandler) throws -> Double {
        let isWrite = (phase == .randomWrite)
        let blocks = Self.blockCount(fileSizeBytes: fileSize, blockBytes: blockBytes)
        guard blocks > 0 else { return 0 }
        var rng = SystemRandomNumberGenerator()
        let clock = ContinuousClock()
        let start = clock.now
        var emitter = ProgressEmitter(phase: phase, clock: clock)
        // force: the very first emission would otherwise be swallowed by the
        // 0.2 s rate gate, lagging the UI phase label by a tick.
        emitter.emit(fraction: 0, totalBytes: 0, progress: progress, force: true)

        var ops: UInt64 = 0
        var elapsed = 0.0
        while elapsed < budget {
            if isCancelled() { throw BenchmarkError.cancelled }
            let idx = UInt64.random(in: 0..<blocks, using: &rng)
            let buffer = buffers[Int(ops % 4)]
            let off = Self.offset(forBlockIndex: idx, blockBytes: blockBytes)
            let n = isWrite
                ? pwrite(fd, buffer, blockBytes, off)
                : pread(fd, buffer, blockBytes, off)
            guard n != -1 else {
                // A volume filling up mid-run deserves the friendly message,
                // not a raw errno (preflight's free-space check is TOCTOU).
                if errno == ENOSPC { throw BenchmarkError.diskFull }
                throw BenchmarkError.ioFailed(operation: isWrite ? "pwrite" : "pread",
                                              errno: errno)
            }
            guard n == blockBytes else {
                throw BenchmarkError.shortIO(expectedBytes: blockBytes, actualBytes: n)
            }
            ops &+= 1
            elapsed = seconds(start.duration(to: clock.now))
            emitter.emit(fraction: min(1, elapsed / budget),
                         totalBytes: ops &* UInt64(blockBytes), progress: progress)
        }
        emitter.emit(fraction: 1, totalBytes: ops &* UInt64(blockBytes),
                     progress: progress, force: true)
        return elapsed > 0 ? Double(ops &* UInt64(blockBytes)) / elapsed : 0
    }

    // MARK: - Concurrent phases (queue depth > 1)

    /// Shared state for concurrent workers: byte counter, first error, and a
    /// rate-gated progress emitter — all behind one lock.
    private final class PhaseShared: @unchecked Sendable {
        let lock = NSLock()
        var doneBytes: UInt64 = 0
        var error: BenchmarkError?
        var lastEmit: ContinuousClock.Instant
        var lastBytes: UInt64 = 0
        let start: ContinuousClock.Instant
        let clock: ContinuousClock
        /// Set for time-boxed phases: fraction = elapsed/budget, not bytes.
        let timeBudget: TimeInterval?

        init(clock: ContinuousClock, timeBudget: TimeInterval? = nil) {
            self.clock = clock
            self.start = clock.now
            self.lastEmit = start
            self.timeBudget = timeBudget
        }

        var hasStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return error != nil
        }

        func fail(_ newError: BenchmarkError) {
            lock.lock()
            if error == nil { error = newError }
            lock.unlock()
        }

        /// Adds completed bytes; when the 0.2 s gate opens, emits progress.
        func add(bytes: Int, of total: UInt64, phase: BenchmarkPhase,
                 progress: ProgressHandler) {
            lock.lock()
            doneBytes &+= UInt64(bytes)
            let now = clock.now
            let sinceEmitComponents = lastEmit.duration(to: now).components
            let sinceEmit = Double(sinceEmitComponents.seconds)
                + Double(sinceEmitComponents.attoseconds) / 1e18
            guard sinceEmit >= 0.2 else { lock.unlock(); return }
            let done = doneBytes
            let instant = Double(done &- lastBytes) / sinceEmit
            let sinceStartComponents = start.duration(to: now).components
            let sinceStart = Double(sinceStartComponents.seconds)
                + Double(sinceStartComponents.attoseconds) / 1e18
            lastEmit = now
            lastBytes = done
            let fraction: Double
            if let timeBudget, timeBudget > 0 {
                fraction = min(1, sinceStart / timeBudget)
            } else {
                fraction = min(1, Double(done) / Double(max(total, 1)))
            }
            // Emit while still holding the lock: releasing first lets two
            // workers deliver out of order (fraction regressions in the UI).
            // The handler is cheap — it only schedules a MainActor hop.
            progress(BenchmarkProgress(
                phase: phase,
                fractionCompleted: fraction,
                instantaneousBytesPerSecond: max(0, instant),
                averageBytesPerSecond: sinceStart > 0 ? Double(done) / sinceStart : 0, processedBytes: done))
            lock.unlock()
        }
    }

    private func concurrentSequentialPhase(
        _ phase: BenchmarkPhase, fd: Int32, buffers: [UnsafeMutableRawPointer],
        blockBytes: Int, fileSize: UInt64, depth: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping ProgressHandler) throws -> Double {
        let isWrite = (phase == .sequentialWrite)
        let total = Self.blockCount(fileSizeBytes: fileSize, blockBytes: blockBytes)
        let clock = ContinuousClock()
        let shared = PhaseShared(clock: clock)
        progress(BenchmarkProgress(phase: phase, fractionCompleted: 0,
                                   instantaneousBytesPerSecond: 0,
                                   averageBytesPerSecond: 0))

        // Worker k handles blocks k, k+depth, k+2·depth… — positioned I/O on
        // one shared fd is thread-safe; each worker owns its buffer.
        DispatchQueue.concurrentPerform(iterations: depth) { worker in
            let buffer = buffers[worker]
            var index = UInt64(worker)
            while index < total {
                if isCancelled() || shared.hasStopped { return }
                let off = Self.offset(forBlockIndex: index, blockBytes: blockBytes)
                let n = isWrite
                    ? pwrite(fd, buffer, blockBytes, off)
                    : pread(fd, buffer, blockBytes, off)
                guard n == blockBytes else {
                    if n == -1, errno == ENOSPC { shared.fail(.diskFull) }
                    else if n == -1 {
                        shared.fail(.ioFailed(operation: isWrite ? "pwrite" : "pread",
                                              errno: errno))
                    } else {
                        shared.fail(.shortIO(expectedBytes: blockBytes, actualBytes: n))
                    }
                    return
                }
                shared.add(bytes: blockBytes, of: fileSize, phase: phase,
                           progress: progress)
                index &+= UInt64(depth)
            }
        }
        if isCancelled() { throw BenchmarkError.cancelled }
        if let error = shared.error { throw error }
        let elapsed = seconds(shared.start.duration(to: clock.now))
        progress(BenchmarkProgress(phase: phase, fractionCompleted: 1,
                                   instantaneousBytesPerSecond: 0,
                                   averageBytesPerSecond: elapsed > 0 ? Double(fileSize) / elapsed : 0, processedBytes: fileSize))
        return elapsed > 0 ? Double(fileSize) / elapsed : 0
    }

    private func concurrentRandomPhase(
        _ phase: BenchmarkPhase, fd: Int32, buffers: [UnsafeMutableRawPointer],
        blockBytes: Int, fileSize: UInt64, seconds budget: TimeInterval, depth: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        progress: @escaping ProgressHandler) throws -> Double {
        let isWrite = (phase == .randomWrite)
        let blocks = Self.blockCount(fileSizeBytes: fileSize, blockBytes: blockBytes)
        guard blocks > 0 else { return 0 }
        let clock = ContinuousClock()
        let shared = PhaseShared(clock: clock, timeBudget: budget)
        progress(BenchmarkProgress(phase: phase, fractionCompleted: 0,
                                   instantaneousBytesPerSecond: 0,
                                   averageBytesPerSecond: 0))
        let deadline = clock.now.advanced(by: .seconds(budget))

        DispatchQueue.concurrentPerform(iterations: depth) { worker in
            var rng = SystemRandomNumberGenerator()
            let buffer = buffers[worker]
            while clock.now < deadline {
                if isCancelled() || shared.hasStopped { return }
                let idx = UInt64.random(in: 0..<blocks, using: &rng)
                let off = Self.offset(forBlockIndex: idx, blockBytes: blockBytes)
                let n = isWrite
                    ? pwrite(fd, buffer, blockBytes, off)
                    : pread(fd, buffer, blockBytes, off)
                guard n == blockBytes else {
                    if n == -1, errno == ENOSPC { shared.fail(.diskFull) }
                    else if n == -1 {
                        shared.fail(.ioFailed(operation: isWrite ? "pwrite" : "pread",
                                              errno: errno))
                    } else {
                        shared.fail(.shortIO(expectedBytes: blockBytes, actualBytes: n))
                    }
                    return
                }
                shared.add(bytes: blockBytes, of: 0, phase: phase,
                           progress: progress)
            }
        }
        if isCancelled() { throw BenchmarkError.cancelled }
        if let error = shared.error { throw error }
        let elapsed = seconds(shared.start.duration(to: clock.now))
        let bytes = shared.doneBytes
        progress(BenchmarkProgress(phase: phase, fractionCompleted: 1,
                                   instantaneousBytesPerSecond: 0,
                                   averageBytesPerSecond: elapsed > 0 ? Double(bytes) / elapsed : 0, processedBytes: bytes))
        return elapsed > 0 ? Double(bytes) / elapsed : 0
    }

    // MARK: - Syscall wrappers

    private func preallocate(fd: Int32, fileSize: UInt64) throws {
        var store = fstore_t()
        store.fst_flags = UInt32(F_ALLOCATECONTIG | F_ALLOCATEALL)
        store.fst_posmode = F_PEOFPOSMODE
        store.fst_offset = 0
        store.fst_length = off_t(fileSize)
        if fcntl(fd, F_PREALLOCATE, &store) == -1 {
            // Fragmented volume: retry without requiring one contiguous run.
            store.fst_flags = UInt32(F_ALLOCATEALL)
            _ = fcntl(fd, F_PREALLOCATE, &store)
            // Preallocation is unsupported on some filesystems (exFAT/msdos);
            // ftruncate below still sizes the file, and ENOSPC surfaces there.
        }
        guard ftruncate(fd, off_t(fileSize)) == 0 else {
            throw BenchmarkError.ioFailed(operation: "ftruncate", errno: errno)
        }
    }

    /// Flushes the drive's write cache to media. Runs between phases for
    /// durability but is excluded from throughput timing, matching
    /// Blackmagic / AmorphousDiskMark / CrystalDiskMark.
    private func fullSync(fd: Int32) throws {
        guard fcntl(fd, F_FULLFSYNC, 0) != -1 else {
            throw BenchmarkError.ioFailed(operation: "F_FULLFSYNC", errno: errno)
        }
    }

    private func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}

/// Rate-limits progress emission to ~5 Hz and tracks instantaneous throughput.
private struct ProgressEmitter {
    let phase: BenchmarkPhase
    let clock: ContinuousClock
    let start: ContinuousClock.Instant
    var lastEmit: ContinuousClock.Instant
    var lastBytes: UInt64 = 0

    init(phase: BenchmarkPhase, clock: ContinuousClock) {
        self.phase = phase
        self.clock = clock
        self.start = clock.now
        self.lastEmit = start
    }

    mutating func emit(fraction: Double, totalBytes: UInt64,
                       progress: DiskBenchmarkEngine.ProgressHandler,
                       force: Bool = false) {
        let now = clock.now
        let sinceEmit = seconds(lastEmit.duration(to: now))
        guard force || sinceEmit >= 0.2 else { return }
        let instant = sinceEmit > 0
            ? Double(totalBytes &- lastBytes) / sinceEmit : 0
        let sinceStart = seconds(start.duration(to: now))
        let average = sinceStart > 0 ? Double(totalBytes) / sinceStart : 0
        progress(BenchmarkProgress(
            phase: phase, fractionCompleted: min(1, max(0, fraction)),
            instantaneousBytesPerSecond: max(0, instant),
            averageBytesPerSecond: average, processedBytes: totalBytes))
        lastEmit = now
        lastBytes = totalBytes
    }

    private func seconds(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
