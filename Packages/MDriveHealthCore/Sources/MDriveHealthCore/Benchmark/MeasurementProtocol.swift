/* Bounded streamed measurement protocol. GPL-3.0-or-later. */
import Foundation

public enum MeasurementOperation: Sendable, Codable {
    case benchmark(BenchmarkConfig), capacity(CapacityVerifyConfig)
}
public struct MeasurementRequest: Sendable, Codable {
    public let version: Int
    public let id: UUID
    public let drive: DriveInfo
    public let volume: VolumeUsage
    public let lockToken: UUID
    public let operation: MeasurementOperation
    public let job: MeasurementJobTicket?
    public init(id: UUID = UUID(), drive: DriveInfo, volume: VolumeUsage, lockToken: UUID, operation: MeasurementOperation, job: MeasurementJobTicket? = nil) {
        version = 3; self.id = id; self.drive = drive; self.volume = volume; self.lockToken = lockToken; self.operation = operation; self.job = job
    }
    func validate() throws {
        guard version == 3, DriveHardwareWorker.validDrive(drive), !drive.isVirtual,
              volume.bsdName.range(of: "^disk[0-9]+(s[0-9]+)+$", options: .regularExpression) != nil,
              volume.mountPoint.hasPrefix("/"), volume.mountPoint.utf8.count <= 4096,
              [volume.name, volume.sharedCapacityKey].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.utf8.contains(0) }),
              !volume.mountPoint.utf8.contains(0), volume.mountIdentity?.volumeUUID != nil, volume.writeIdentity?.volumeUUID != nil, volume.writeDirectoryIdentity?.isValid == true else {
            throw MeasurementWorkerError.protocolViolation
        }
        switch operation { case .benchmark(let config): try config.validate(); case .capacity(let config): try config.validate() }
        try job?.validate()
        guard job == nil || job?.id == id else { throw MeasurementWorkerError.protocolViolation }
    }
}
enum MeasurementPayload: Sendable, Codable {
    case prepared
    case benchmarkProgress(BenchmarkProgress), capacityProgress(CapacityVerifyProgress)
    case cleaning(Int)
    case benchmarkResult(BenchmarkResult), capacityResult(CapacityVerifyResult)
    case failure(cancelled: Bool, message: String)
    case journalReceipt(String)
    case resultNotPersisted(MeasurementJobTerminal, message: String)
}
struct MeasurementFrame: Sendable, Codable {
    let version: Int
    let id: UUID
    let sequence: Int
    let payload: MeasurementPayload
    init(id: UUID, sequence: Int, payload: MeasurementPayload) { version = 3; self.id = id; self.sequence = sequence; self.payload = payload }
}
public enum MeasurementWorkerError: Error, LocalizedError, Sendable {
    case protocolViolation, remote(String)
    case resultNotPersisted(MeasurementJobRecord, message: String)
    case resultNotDelivered(MeasurementJobRecord, message: String)
    public var errorDescription: String? {
        switch self {
        case .protocolViolation: return "Invalid measurement worker progress or result"
        case .remote(let detail): return detail
        case .resultNotPersisted(_, let message): return "Measurement completed but its journal could not be confirmed: " + message
        case .resultNotDelivered(_, let message): return "Measurement result was recovered after its worker connection failed: " + message
        }
    }
}

/// Owned by one supervisor thread; bounded framing and no progress history.
final class MeasurementStream: @unchecked Sendable {
    static let frameLimit = 16 * 1024
    static let frameCountLimit = 4_000_000
    let request: MeasurementRequest
    private let job: MeasurementJobLease?
    private let progress: @Sendable (MeasurementPayload) -> Void
    private var partial = Data()
    private var sequence = 0
    private var prepared = false
    private var terminal: MeasurementPayload?
    private var cleaningCount: Int?
    private var benchmarkPhase = -1
    private var phaseFraction: Double = 0
    private var phaseBytes: UInt64 = 0
    private var capacityPhase = -1
    private var capacityTotal: UInt64 = 0
    private var invalid = false
    private var journalReceipt: String?

    init(request: MeasurementRequest, job: MeasurementJobLease? = nil, progress: @escaping @Sendable (MeasurementPayload) -> Void) {
        self.request = request; self.job = job; self.progress = progress
    }
    func consume(_ bytes: Data) throws -> Bool {
        guard !invalid else { throw MeasurementWorkerError.protocolViolation }
        do { return try consumeFrames(bytes) }
        catch { invalid = true; throw error }
    }
    private func consumeFrames(_ bytes: Data) throws -> Bool {
        var live = false
        // A chunk can contain many complete frames. Bound the unfinished frame,
        // rather than accumulating a multi-hour stdout buffer.
        for byte in bytes {
            if byte == 10 {
                guard !partial.isEmpty, terminal == nil, sequence < Self.frameCountLimit else { throw MeasurementWorkerError.protocolViolation }
                let frame = try JSONDecoder().decode(MeasurementFrame.self, from: partial)
                partial.removeAll(keepingCapacity: true)
                guard frame.version == 3, frame.id == request.id, frame.sequence == sequence + 1 else { throw MeasurementWorkerError.protocolViolation }
                sequence += 1
                live = try accept(frame.payload) || live
            } else {
                guard partial.count < Self.frameLimit, terminal == nil else { throw MeasurementWorkerError.protocolViolation }
                partial.append(byte)
            }
        }
        return live
    }
    private func accept(_ payload: MeasurementPayload) throws -> Bool {
        if journalReceipt != nil {
            switch payload { case .benchmarkResult, .capacityResult, .failure: break; default: throw MeasurementWorkerError.protocolViolation }
        }
        switch payload {
        case .journalReceipt(let hash):
            guard let job, request.job == job.ticket, journalReceipt == nil, hash.utf8.count == 64,
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MeasurementWorkerError.protocolViolation }
            journalReceipt = hash; return false
        case .resultNotPersisted(let value, let message):
            guard let job, request.job == job.ticket, journalReceipt == nil,
                  !message.isEmpty, message.utf8.count <= 4096, !message.utf8.contains(0) else { throw MeasurementWorkerError.protocolViolation }
            try value.validate(intent: job.intent)
            switch value.outcome {
            case .benchmark(let result): try validateBenchmarkTerminal(result)
            case .capacity(let result): try validateCapacityTerminal(result)
            case .cancelled, .failed, .notStarted: break
            }
            terminal = payload; return false
        case .prepared:
            guard !prepared, sequence == 1 else { throw MeasurementWorkerError.protocolViolation }; prepared = true; return true
        case .failure(_, let message):
            guard !message.isEmpty, message.utf8.count <= 4096 else { throw MeasurementWorkerError.protocolViolation }
            terminal = payload; return false
        case .cleaning(let count):
            guard prepared, (0...DiskWorkspaceRecovery.maximumFiles).contains(count),
                  cleaningCount.map({ count >= $0 }) ?? true else { throw MeasurementWorkerError.protocolViolation }
            if case .benchmark = request.operation, count > 1 { throw MeasurementWorkerError.protocolViolation }
            let live = cleaningCount == nil || count > cleaningCount!
            cleaningCount = count; progress(payload); return live
        case .benchmarkProgress(let p):
            guard prepared, cleaningCount == nil, case .benchmark(let config) = request.operation else { throw MeasurementWorkerError.protocolViolation }
            try validRate(p.instantaneousBytesPerSecond); try validRate(p.averageBytesPerSecond); try validFraction(p.fractionCompleted)
            let phases: [BenchmarkPhase] = config.includeRandomPhases ? [.sequentialWrite,.sequentialRead,.randomWrite,.randomRead] : [.sequentialWrite,.sequentialRead]
            guard let phase = phases.firstIndex(of: p.phase), phase == benchmarkPhase || phase == benchmarkPhase + 1 else { throw MeasurementWorkerError.protocolViolation }
            let changed = phase != benchmarkPhase
            if changed {
                guard benchmarkPhase < 0 || phaseFraction == 1 else { throw MeasurementWorkerError.protocolViolation }
                benchmarkPhase = phase; phaseBytes = 0; phaseFraction = 0
            }
            guard p.processedBytes >= phaseBytes, p.fractionCompleted >= phaseFraction else { throw MeasurementWorkerError.protocolViolation }
            if phase < 2 { guard p.processedBytes <= config.fileSizeBytes, p.processedBytes % UInt64(config.sequentialBlockBytes) == 0,
                abs(p.fractionCompleted - Double(p.processedBytes) / Double(config.fileSizeBytes)) < 0.000001 else { throw MeasurementWorkerError.protocolViolation } }
            else { guard p.processedBytes % UInt64(config.randomBlockBytes) == 0 else { throw MeasurementWorkerError.protocolViolation } }
            let live = changed || p.processedBytes > phaseBytes
            phaseBytes = p.processedBytes; phaseFraction = p.fractionCompleted; progress(payload); return live
        case .capacityProgress(let p):
            guard prepared, cleaningCount == nil, case .capacity(let config) = request.operation else { throw MeasurementWorkerError.protocolViolation }
            try validRate(p.instantaneousBytesPerSecond); try validFraction(p.fractionCompleted)
            let phase = p.phase == .filling ? 0 : 1, changed = phase != capacityPhase
            guard phase >= capacityPhase, p.totalBytes > 0, p.bytesProcessed <= p.totalBytes,
                  config.maxBytes.map({ p.totalBytes <= $0 }) ?? true else { throw MeasurementWorkerError.protocolViolation }
            if changed {
                if capacityPhase == 0 { guard p.totalBytes <= capacityTotal else { throw MeasurementWorkerError.protocolViolation } }
                capacityPhase = phase; phaseBytes = 0; phaseFraction = 0; capacityTotal = p.totalBytes
            }
            guard p.totalBytes == capacityTotal, p.bytesProcessed >= phaseBytes, p.fractionCompleted >= phaseFraction,
                  abs(p.fractionCompleted - Double(p.bytesProcessed) / Double(p.totalBytes)) < 0.000001 else { throw MeasurementWorkerError.protocolViolation }
            let live = changed || p.bytesProcessed > phaseBytes
            phaseBytes = p.bytesProcessed; phaseFraction = p.fractionCompleted; progress(payload); return live
        case .benchmarkResult(let result):
            guard request.job == nil || journalReceipt != nil else { throw MeasurementWorkerError.protocolViolation }
            try validateBenchmarkTerminal(result)
            terminal = payload; return true
        case .capacityResult(let result):
            guard request.job == nil || journalReceipt != nil else { throw MeasurementWorkerError.protocolViolation }
            try validateCapacityTerminal(result)
            terminal = payload; return true
        }
    }

    private func validateBenchmarkTerminal(_ result: BenchmarkResult) throws {
        guard prepared, cleaningCount != nil, case .benchmark(let config) = request.operation,
              benchmarkPhase == (config.includeRandomPhases ? 3 : 1), phaseFraction == 1 else { throw MeasurementWorkerError.protocolViolation }
        try MeasurementResultValidation.benchmark(result, volume: request.volume, config: config)
    }
    private func validateCapacityTerminal(_ result: CapacityVerifyResult) throws {
        guard prepared, cleaningCount != nil, case .capacity(let config) = request.operation else { throw MeasurementWorkerError.protocolViolation }
        try MeasurementResultValidation.capacity(result, volume: request.volume, config: config)
    }

    private func validRate(_ value: Double) throws { guard value.isFinite, value >= 0 else { throw MeasurementWorkerError.protocolViolation } }
    private func validFraction(_ value: Double) throws { guard value.isFinite, (0...1).contains(value) else { throw MeasurementWorkerError.protocolViolation } }
    func finish() throws -> MeasurementPayload {
        guard !invalid, partial.isEmpty, let terminal else { throw MeasurementWorkerError.protocolViolation }
        if case .resultNotPersisted(let value, let message) = terminal {
            guard let job else { throw MeasurementWorkerError.protocolViolation }
            throw MeasurementWorkerError.resultNotPersisted(.init(intent: job.intent, terminal: value), message: message)
        }
        if let job {
            let record = try job.record()
            guard try record.recordSHA256 == journalReceipt, let saved = record.terminal else { throw MeasurementWorkerError.protocolViolation }
            switch (saved.outcome, terminal) {
            case (.benchmark(let value), .benchmarkResult(let received)):
                guard try MeasurementJournalCoding.encode(value) == MeasurementJournalCoding.encode(received) else { throw MeasurementWorkerError.protocolViolation }
            case (.capacity(let value), .capacityResult(let received)):
                guard try MeasurementJournalCoding.encode(value) == MeasurementJournalCoding.encode(received) else { throw MeasurementWorkerError.protocolViolation }
            case (.cancelled, .failure(true, _)): break
            case (.failed(let value), .failure(false, let received)), (.notStarted(let value), .failure(false, let received)):
                guard value == received else { throw MeasurementWorkerError.protocolViolation }
            default: throw MeasurementWorkerError.protocolViolation
            }
        }
        if case .failure(let cancelled, let message) = terminal {
            if cancelled { throw BenchmarkError.cancelled }; throw MeasurementWorkerError.remote(message)
        }
        return terminal
    }
    func resolveCancellation() throws -> MeasurementPayload {
        guard !invalid, partial.isEmpty, terminal != nil else {
            throw MeasurementWorkerError.remote("Measurement stopped before cleanup was confirmed. Inspect workspace \(WorkspaceJournal.prefix)\(request.id.uuidString) before retrying.")
        }
        return try finish()
    }
}
