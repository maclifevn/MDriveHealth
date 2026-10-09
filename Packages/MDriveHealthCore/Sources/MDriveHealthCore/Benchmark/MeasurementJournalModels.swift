/* Durable measurement metadata; no automatic re-execution. GPL-3.0-or-later. */
import Foundation
import CryptoKit

public enum MeasurementHistoryPolicy: String, Codable, Sendable { case archive, omit }
public struct MeasurementJobIntent: Codable, Sendable, Identifiable {
    public let version: Int
    public let id: UUID
    public let nonce: UUID
    public let createdAt: Date
    public let drive: DriveInfo
    public let driveKey: String
    public let volume: VolumeUsage
    public let writeDirectoryPath: String
    public let operation: MeasurementOperation
    public let origin: MeasurementOrigin?
    public let historyPolicy: MeasurementHistoryPolicy?
    public init(id: UUID = UUID(), createdAt: Date = Date(), drive: DriveInfo, driveKey: String, volume: VolumeUsage, operation: MeasurementOperation, origin: MeasurementOrigin? = nil, historyPolicy: MeasurementHistoryPolicy = .archive) {
        version = 2; self.id = id; nonce = UUID(); self.createdAt = createdAt; self.drive = drive; self.driveKey = driveKey
        self.volume = volume; writeDirectoryPath = DiskWorkspaceRecovery.writeDirectoryPath(for: volume); self.operation = operation
        self.origin = origin ?? MeasurementOrigin(drive: drive)
        self.historyPolicy = historyPolicy
    }
    public func validate() throws {
        guard (version == 1 || version == 2), version != 2 || (origin != nil && historyPolicy != nil), createdAt.timeIntervalSince1970.isFinite,
              !driveKey.isEmpty, driveKey.utf8.count <= 1024, !driveKey.utf8.contains(0),
              writeDirectoryPath.hasPrefix("/"), writeDirectoryPath.utf8.count <= 4096, !writeDirectoryPath.utf8.contains(0) else { throw MeasurementJournalError.invalidRecord }
        try MeasurementRequest(id: id, drive: drive, volume: volume, lockToken: nonce, operation: operation).validate()
        try origin?.validate(drive: drive)
    }
}
public enum MeasurementJobOutcome: Codable, Sendable {
    case benchmark(BenchmarkResult), capacity(CapacityVerifyResult), cancelled, notStarted(String), failed(String)
    public var cleanupConfirmed: Bool {
        switch self { case .benchmark, .capacity, .cancelled, .notStarted: return true; case .failed: return false }
    }
}
public struct MeasurementJobTerminal: Codable, Sendable {
    public let id: UUID
    public let nonce: UUID
    public let completedAt: Date
    public let outcome: MeasurementJobOutcome
    public init(intent: MeasurementJobIntent, outcome: MeasurementJobOutcome, completedAt: Date = Date()) {
        id = intent.id; nonce = intent.nonce; self.outcome = outcome; self.completedAt = completedAt
    }
    public func validate(intent: MeasurementJobIntent) throws {
        try intent.validate()
        guard id == intent.id, nonce == intent.nonce, completedAt.timeIntervalSince1970.isFinite else { throw MeasurementJournalError.invalidRecord }
        switch (intent.operation, outcome) {
        case (.benchmark(let config), .benchmark(let result)): try MeasurementResultValidation.benchmark(result, volume: intent.volume, config: config)
        case (.capacity(let config), .capacity(let result)): try MeasurementResultValidation.capacity(result, volume: intent.volume, config: config)
        case (_, .cancelled): break
        case (_, .failed(let message)), (_, .notStarted(let message)):
            guard !message.isEmpty, message.utf8.count <= 4096, !message.utf8.contains(0) else { throw MeasurementJournalError.invalidRecord }
        default: throw MeasurementJournalError.invalidRecord
        }
    }
}
public struct MeasurementJobRecord: Codable, Sendable, Identifiable {
    public var id: UUID { intent.id }
    public let intent: MeasurementJobIntent
    /// Nil means an interrupted run, never an empty successful result.
    public let terminal: MeasurementJobTerminal?
    public init(intent: MeasurementJobIntent, terminal: MeasurementJobTerminal?) { self.intent = intent; self.terminal = terminal }
    public func validate() throws { try intent.validate(); try terminal?.validate(intent: intent) }
    public var recordSHA256: String { get throws { try validate(); let data = try MeasurementJournalCoding.encode(self); return MeasurementJournalCoding.hash(data) } }
}
public struct MeasurementHistoryReceipt: Sendable {
    public let id: UUID
    public let recordSHA256: String
    init(id: UUID, recordSHA256: String) { self.id = id; self.recordSHA256 = recordSHA256 }
}
public struct MeasurementJobTicket: Codable, Sendable, Equatable {
    public let version: Int
    public let id: UUID
    public let nonce: UUID
    public let directory: WorkspaceDirectoryIdentity
    public let intentSHA256: String
    func validate() throws {
        guard version == 1, directory.isValid, intentSHA256.utf8.count == 64,
              intentSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw MeasurementJournalError.invalidRecord }
    }
}
public struct MeasurementRecoveredJob: Sendable, Identifiable {
    public enum State: Sendable { case active, interrupted, completed, acknowledged, unverified }
    public var id: String { name }
    public let name: String
    public let state: State
    public let record: MeasurementJobRecord?
    public let cleanupConfirmed: Bool
    public let diagnostic: String?
}
public struct MeasurementJournalScan: Sendable {
    public let jobs: [MeasurementRecoveredJob]
    public let unknownEntries: [String]
}
public enum MeasurementJournalError: Error, LocalizedError {
    case unsafeDirectory, invalidRecord, changed, busy, budgetExceeded, unconfirmedCleanup, receiptMismatch, io(String, Int32)
    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory: return "Measurement journal directory or permissions could not be verified"
        case .invalidRecord: return "Measurement journal record is incomplete, invalid or bound to another run"
        case .changed: return "Measurement journal filesystem identity changed"
        case .busy: return "Measurement journal is in use by another process"
        case .budgetExceeded: return "Measurement journal exceeded its bounded record budget"
        case .unconfirmedCleanup: return "Measurement workspace cleanup remains unconfirmed"
        case .receiptMismatch: return "History did not acknowledge this exact measurement record"
        case .io(let op, let code): return "Measurement journal \(op) failed (\(code))"
        }
    }
}
// One canonical payload encoding backs file checksums, SQLite CAS and receipts.
// Hash raw payload bytes before decoding so unknown/changed fields cannot be
// silently ignored when validating a stored envelope.
enum MeasurementJournalCoding {
    static let recordLimit = 65_536
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= recordLimit else { throw MeasurementJournalError.budgetExceeded }; return data
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Envelope: Codable { let version: Int; let payload: Data; let sha256: String }
    static func wrap<T: Encodable>(_ value: T) throws -> Data {
        let data = try encode(value); return try encode(Envelope(version: 1, payload: data, sha256: hash(data))) + Data([10])
    }
    static func unwrap<T: Codable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= recordLimit + 1, data.last == 10 else { throw MeasurementJournalError.invalidRecord }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, hash(envelope.payload) == envelope.sha256 else { throw MeasurementJournalError.invalidRecord }
        let value = try JSONDecoder().decode(type, from: envelope.payload)
        // These files are emitted only in our canonical encoding. Unknown
        // fields or foreign encodings must be preserved, not discarded when
        // decoding a smaller model and later acknowledging the record.
        guard try encode(value) == envelope.payload, try encode(envelope) + Data([10]) == data else { throw MeasurementJournalError.invalidRecord }
        return value
    }
}

// Published in the root before deleting any acknowledged job metadata. Its
// immutable file hashes permit resuming GC after intent/result files vanish.
struct MeasurementConsumption: Codable {
    let version: Int
    let id: UUID
    let nonce: UUID
    let directory: WorkspaceDirectoryIdentity
    let rootVolumeUUID: String?
    let historySHA256: String
    var omittedHistory: Bool? = nil
    let files: [String: String]
    func validate() throws {
        let hexadecimal: (String) -> Bool = { $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
        guard version == 1, directory.isValid, files.count <= 3, files["intent.json"] != nil,
              files.keys.allSatisfy({ ["intent.json","terminal.json","cleanup.json"].contains($0) }),
              files.values.allSatisfy(hexadecimal), hexadecimal(historySHA256) else { throw MeasurementJournalError.invalidRecord }
    }
}
