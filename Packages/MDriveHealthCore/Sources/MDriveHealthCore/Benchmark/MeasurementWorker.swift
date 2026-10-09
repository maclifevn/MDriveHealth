/* Isolated measurement engine and cooperative child cancellation. GPL-3.0-or-later. */
import Foundation
import Darwin
import CSMART

public struct MeasurementWorkerClient: Sendable {
    public let executable: String
    public let arguments: [String]
    public let idleTimeout: TimeInterval
    public let timeout: TimeInterval
    public let terminateGrace: TimeInterval
    public let journalRootURL: URL?
    public init(executable: String, arguments: [String] = ["--measurement-worker"], idleTimeout: TimeInterval = 30,
                timeout: TimeInterval = 604_800, terminateGrace: TimeInterval = 10, journalRootURL: URL? = nil) {
        self.executable = executable; self.arguments = arguments; self.idleTimeout = idleTimeout; self.timeout = timeout; self.terminateGrace = terminateGrace; self.journalRootURL = journalRootURL
    }
    public static var bundled: Self {
        .init(executable: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MDriveHealthWorker").path ?? "/MDriveHealthWorker-unavailable")
    }
    public func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID = UUID(), lease: DriveCommandLock.Lease, job: MeasurementJobLease? = nil,
                          isCancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping DiskBenchmarkEngine.ProgressHandler = { _ in },
                          cleaning: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> BenchmarkResult {
        let job = try job ?? prepareJobBlocking(.init(id: id, drive: drive, driveKey: DriveIdentity.resolve(for: drive).key, volume: volume, operation: .benchmark(config)))
        let request = MeasurementRequest(id: id, drive: drive, volume: volume, lockToken: lease.token, operation: .benchmark(config), job: job.ticket)
        let result = try await run(request: request, lease: lease, job: job, isCancelled: isCancelled) {
            switch $0 { case .benchmarkProgress(let p): progress(p); case .cleaning(let count): cleaning(count); default: break }
        }
        guard case .benchmarkResult(let result) = result else { throw MeasurementWorkerError.protocolViolation }; return result
    }
    public func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID = UUID(), lease: DriveCommandLock.Lease, job: MeasurementJobLease? = nil,
                         isCancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping CapacityVerifier.ProgressHandler = { _ in },
                         cleaning: @escaping @Sendable (Int) -> Void = { _ in }) async throws -> CapacityVerifyResult {
        let job = try job ?? prepareJobBlocking(.init(id: id, drive: drive, driveKey: DriveIdentity.resolve(for: drive).key, volume: volume, operation: .capacity(config)))
        let request = MeasurementRequest(id: id, drive: drive, volume: volume, lockToken: lease.token, operation: .capacity(config), job: job.ticket)
        let result = try await run(request: request, lease: lease, job: job, isCancelled: isCancelled) {
            switch $0 { case .capacityProgress(let p): progress(p); case .cleaning(let count): cleaning(count); default: break }
        }
        guard case .capacityResult(let result) = result else { throw MeasurementWorkerError.protocolViolation }; return result
    }
    public func benchmarkBlocking(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID = UUID(), lease: DriveCommandLock.Lease, job: MeasurementJobLease? = nil,
                                  isCancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping DiskBenchmarkEngine.ProgressHandler = { _ in }) throws -> BenchmarkResult {
        let job = try job ?? prepareJobBlocking(.init(id: id, drive: drive, driveKey: DriveIdentity.resolve(for: drive).key, volume: volume, operation: .benchmark(config)))
        let request = MeasurementRequest(id: id, drive: drive, volume: volume, lockToken: lease.token, operation: .benchmark(config), job: job.ticket)
        guard case .benchmarkResult(let result) = try runBlocking(request: request, lease: lease, job: job, isCancelled: isCancelled, progress: {
            if case .benchmarkProgress(let p) = $0 { progress(p) }
        }) else { throw MeasurementWorkerError.protocolViolation }; return result
    }
    public func capacityBlocking(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID = UUID(), lease: DriveCommandLock.Lease, job: MeasurementJobLease? = nil,
                                 isCancelled: @escaping @Sendable () -> Bool = { false }, progress: @escaping CapacityVerifier.ProgressHandler = { _ in }) throws -> CapacityVerifyResult {
        let job = try job ?? prepareJobBlocking(.init(id: id, drive: drive, driveKey: DriveIdentity.resolve(for: drive).key, volume: volume, operation: .capacity(config)))
        let request = MeasurementRequest(id: id, drive: drive, volume: volume, lockToken: lease.token, operation: .capacity(config), job: job.ticket)
        guard case .capacityResult(let result) = try runBlocking(request: request, lease: lease, job: job, isCancelled: isCancelled, progress: {
            if case .capacityProgress(let p) = $0 { progress(p) }
        }) else { throw MeasurementWorkerError.protocolViolation }; return result
    }
    public func prepareJob(_ intent: MeasurementJobIntent) async throws -> MeasurementJobLease {
        try await Task.detached(priority: .utility) { try prepareJobBlocking(intent) }.value
    }
    public func prepareJobBlocking(_ intent: MeasurementJobIntent) throws -> MeasurementJobLease {
        let journal = try MeasurementJournal(rootURL: journalRootURL ?? MeasurementJournal.defaultRootURL())
        return try journal.prepare(intent)
    }
    public func discardCommitted(_ receipt: MeasurementHistoryReceipt) async throws {
        try await Task.detached(priority: .utility) {
            try MeasurementJournal(rootURL: journalRootURL ?? MeasurementJournal.defaultRootURL()).discardCommitted(receipt)
        }.value
    }
    private func recoveredResult(after error: Error, job: MeasurementJobLease) throws {
        guard let command = error as? CommandError, command.pendingChild == nil, command.processID != nil,
              let record = try? job.record(), let terminal = record.terminal else { return }
        switch terminal.outcome {
        case .benchmark, .capacity: throw MeasurementWorkerError.resultNotDelivered(record, message: command.localizedDescription)
        case .cancelled, .failed, .notStarted: return
        }
    }
    private func command(request: MeasurementRequest, lease: DriveCommandLock.Lease, job: MeasurementJobLease, stream: MeasurementStream) throws -> ProcessCommand {
        try request.validate(); try job.validate(request: request)
        var command = ProcessCommand(executable, arguments, timeout: timeout, scope: "measurement:\(request.drive.id)")
        command.input = try JSONEncoder().encode(request)
        guard command.input.count <= MeasurementWorker.requestLimit else { throw MeasurementWorkerError.protocolViolation }
        command.inheritedFileDescriptors[3] = try lease.delegatedFD()
        command.inheritedFileDescriptors[5] = try job.delegatedFD()
        command.streamingStdout = .init(byteLimit: 1_073_741_824, consume: { try stream.consume($0) })
        command.idleTimeout = idleTimeout; command.terminateGrace = terminateGrace; command.stdoutLimit = 0
        return command
    }
    private func run(request: MeasurementRequest, lease: DriveCommandLock.Lease, job: MeasurementJobLease,
                     isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (MeasurementPayload) -> Void) async throws -> MeasurementPayload {
        defer { withExtendedLifetime((lease, job)) {} }
        let stream = MeasurementStream(request: request, job: job, progress: progress)
        do { _ = try await BoundedProcess.run(command(request: request, lease: lease, job: job, stream: stream), isCancelled: isCancelled).requireSuccess() }
        catch let error as CommandError where error.reason == .cancelled && error.pendingChild == nil { return try stream.resolveCancellation() }
        catch { try recoveredResult(after: error, job: job); throw error }
        return try stream.finish()
    }
    private func runBlocking(request: MeasurementRequest, lease: DriveCommandLock.Lease, job: MeasurementJobLease,
                             isCancelled: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (MeasurementPayload) -> Void) throws -> MeasurementPayload {
        defer { withExtendedLifetime((lease, job)) {} }
        let stream = MeasurementStream(request: request, job: job, progress: progress)
        do { _ = try BoundedProcess.run(command(request: request, lease: lease, job: job, stream: stream), isCancelled: isCancelled).requireSuccess() }
        catch let error as CommandError where error.reason == .cancelled && error.pendingChild == nil { return try stream.resolveCancellation() }
        catch { try recoveredResult(after: error, job: job); throw error }
        return try stream.finish()
    }
}

private final class MeasurementLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = DispatchTime.now().uptimeNanoseconds
    private var finished = false
    func progressed() { lock.lock(); lastProgress = DispatchTime.now().uptimeNanoseconds; lock.unlock() }
    func finish() { lock.lock(); finished = true; lock.unlock() }
    func status() -> (Bool, UInt64) { lock.lock(); defer { lock.unlock() }; return (finished, lastProgress) }
}
private final class MeasurementWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let request: MeasurementRequest
    private let lifetime: MeasurementLifetime
    private let output: FileHandle
    private var sequence = 0
    private var failure: Error?
    private var lastClean = DispatchTime.now().uptimeNanoseconds
    private var cleanStarted = false
    private var lastBytes: UInt64 = 0
    private var lastPhase: String?
    init(request: MeasurementRequest, lifetime: MeasurementLifetime, output: FileHandle) { self.request = request; self.lifetime = lifetime; self.output = output }
    func emit(_ payload: MeasurementPayload) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil else { return }
        let live: Bool
        switch payload {
        case .prepared: live = true
        case .benchmarkProgress(let p):
            live = lastPhase != p.phase.rawValue || p.processedBytes > lastBytes
            lastPhase = p.phase.rawValue; lastBytes = p.processedBytes
        case .capacityProgress(let p):
            live = lastPhase != p.phase.rawValue || p.bytesProcessed > lastBytes
            lastPhase = p.phase.rawValue; lastBytes = p.bytesProcessed
        case .cleaning(let count):
            let now = DispatchTime.now().uptimeNanoseconds
            // Cleanup can have 131k files. Keep both stdout and UI cadence bounded.
            if cleanStarted && now - lastClean < 200_000_000 { return }
            live = !cleanStarted || UInt64(count) > lastBytes
            cleanStarted = true; lastClean = now; lastBytes = UInt64(count)
        case .benchmarkResult, .capacityResult, .journalReceipt: live = true
        case .failure, .resultNotPersisted: live = false
        }
        if live { lifetime.progressed() }
        do {
            guard sequence < MeasurementStream.frameCountLimit else { throw MeasurementWorkerError.protocolViolation }
            sequence += 1
            var bytes = try JSONEncoder().encode(MeasurementFrame(id: request.id, sequence: sequence, payload: payload))
            guard bytes.count <= MeasurementStream.frameLimit else { throw MeasurementWorkerError.protocolViolation }
            bytes.append(10); try output.write(contentsOf: bytes)
        } catch { failure = error; MDMeasurementRequestCancellation() }
    }
    func requireSuccess() throws { lock.lock(); defer { lock.unlock() }; if let failure { throw failure } }
}

public enum MeasurementWorker {
    static let requestLimit = 64 * 1024
    public static func runStandardIO() -> Int32 {
        serve(requireJournal: true, prepare: { request in
            let status = try DriveHardwareWorker.execute(.measurementStatus(request.drive, lockToken: request.lockToken))
            if request.drive.smartInterface == .ata {
                guard case .inspection(let inspection) = status, let status = inspection.reading?.ataSelfTest else { throw HardwareWorkerError.selfTestUnavailable }
                guard !status.inProgress else { throw HardwareWorkerError.selfTestRunning }
            }
            try DriveHardwareWorker.validateWorkspaceVolume(request.volume, drive: request.drive)
        }) { request, cancelled, benchmark, capacity, cleaning in
            if cancelled() { throw BenchmarkError.cancelled }
            switch request.operation {
            case .benchmark(let config): return .benchmarkResult(try DiskBenchmarkEngine().run(volume: request.volume, config: config, isCancelled: cancelled,
                progress: benchmark, measurementID: request.id, cleanupProgress: cleaning))
            case .capacity(let config): return .capacityResult(try CapacityVerifier().run(volume: request.volume, config: config, isCancelled: cancelled,
                progress: capacity, measurementID: request.id, cleanupProgress: cleaning))
            }
        }
    }
    /// Internal fixture boundary. Production always uses the validated executor
    /// above; neither requests nor environment variables select this seam.
    static func serve(output: FileHandle = .standardOutput, requireJournal: Bool = false, prepare: (MeasurementRequest) throws -> Void = { _ in },
                      afterJournal: (MeasurementJobRecord, @escaping @Sendable () -> Bool) -> Void = { _, _ in },
                      execute: (MeasurementRequest, @escaping @Sendable () -> Bool,
                                @escaping DiskBenchmarkEngine.ProgressHandler, @escaping CapacityVerifier.ProgressHandler,
                                @escaping @Sendable (Int) -> Void) throws -> MeasurementPayload) -> Int32 {
        guard MDMeasurementInstallCancellationHandlers() == 0 else { return 2 }
        let parent = getppid(), lifetime = MeasurementLifetime(), began = DispatchTime.now().uptimeNanoseconds
        guard parent > 1 else { return 2 }
        defer { lifetime.finish() }
        let guardian = Thread {
            var cancellationAt: UInt64?
            while true {
                let (finished, lastProgress) = lifetime.status(); if finished { return }
                let now = DispatchTime.now().uptimeNanoseconds
                if getppid() != parent || now - began >= 604_800_000_000_000 || now - lastProgress >= 30_000_000_000 { MDMeasurementRequestCancellation() }
                if MDMeasurementIsCancelled() {
                    if cancellationAt == nil { cancellationAt = now }
                    if now - cancellationAt! >= 10_000_000_000 { Darwin.kill(getpid(), SIGKILL); return }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        guardian.name = "MDriveHealth.measurement-lifetime"; guardian.qualityOfService = .utility; guardian.start()
        do {
            var bytes = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 8192), !chunk.isEmpty {
                guard bytes.count + chunk.count <= requestLimit else { throw MeasurementWorkerError.protocolViolation }; bytes.append(chunk)
            }
            let request = try JSONDecoder().decode(MeasurementRequest.self, from: bytes); try request.validate()
            let job: MeasurementJobLease?
            if let ticket = request.job {
                job = try MeasurementJobLease.adopting(descriptor: 5, ticket: ticket)
                try job!.validate(request: request)
                guard try job!.record().terminal == nil, try !job!.cleanupConfirmed() else { throw MeasurementJournalError.changed }
            } else {
                guard !requireJournal else { throw MeasurementJournalError.invalidRecord }; job = nil
            }
            let writer = MeasurementWriter(request: request, lifetime: lifetime, output: output)
            let result: MeasurementPayload
            var executionBegan = false
            do {
                try prepare(request)
                writer.emit(.prepared); try writer.requireSuccess()
                if MDMeasurementIsCancelled() { throw BenchmarkError.cancelled }
                executionBegan = true
                result = try execute(request, { MDMeasurementIsCancelled() }, { writer.emit(.benchmarkProgress($0)) },
                                     { writer.emit(.capacityProgress($0)) }, { writer.emit(.cleaning($0)) })
            } catch {
                let cleanupFailed: Bool
                if case BenchmarkError.cleanupFailed = error { cleanupFailed = true } else { cleanupFailed = false }
                result = .failure(cancelled: (error as? BenchmarkError) == .cancelled || (MDMeasurementIsCancelled() && !cleanupFailed),
                                  message: String(decoding: Data(error.localizedDescription.utf8.prefix(4093)), as: UTF8.self))
            }
            if let job {
                let outcome: MeasurementJobOutcome
                switch result {
                case .benchmarkResult(let value): outcome = .benchmark(value)
                case .capacityResult(let value): outcome = .capacity(value)
                case .failure(true, _): outcome = .cancelled
                case .failure(false, let message): outcome = executionBegan ? .failed(message) : .notStarted(message)
                default: throw MeasurementWorkerError.protocolViolation
                }
                let terminal = MeasurementJobTerminal(intent: job.intent, outcome: outcome)
                do {
                    try job.writeTerminal(terminal)
                    let record = MeasurementJobRecord(intent: job.intent, terminal: terminal)
                    afterJournal(record, { MDMeasurementIsCancelled() })
                    writer.emit(.journalReceipt(try record.recordSHA256)); writer.emit(result)
                } catch {
                    writer.emit(.resultNotPersisted(terminal, message: String(decoding: Data(error.localizedDescription.utf8.prefix(4093)), as: UTF8.self)))
                }
                withExtendedLifetime(job) {}
            } else { writer.emit(result) }
            try writer.requireSuccess(); return 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Measurement worker request/stream failed\n".utf8)); return 2
        }
    }
}
