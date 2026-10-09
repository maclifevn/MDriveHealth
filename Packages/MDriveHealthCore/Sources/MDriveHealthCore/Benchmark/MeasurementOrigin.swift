/* Physical origin of a recovery claim. GPL-3.0-or-later. */
import Foundation
import Darwin

/// Filesystem identifiers may survive cloning. A recovery claim also needs a
/// unique serial identity, or the exact attachment within one OS boot session.
public struct MeasurementOrigin: Codable, Sendable, Equatable {
    public let serialIdentityKey: String?
    public let bootSessionID: UUID?
    public let registryEntryID: UInt64
    public let model: String
    public let sizeBytes: UInt64
    public let interconnect: String

    public static let currentBootSessionID: UUID? = {
        var bytes = [CChar](repeating: 0, count: 128), count = 128
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            sysctlbyname("kern.bootsessionuuid", buffer.baseAddress, &count, nil, 0)
        }
        guard result == 0, count > 1, count <= bytes.count, bytes[count - 1] == 0 else { return nil }
        return UUID(uuidString: String(cString: bytes))
    }()

    public init(drive: DriveInfo, identity: DriveIdentity? = nil, bootSessionID: UUID? = Self.currentBootSessionID) {
        let resolved = identity ?? DriveIdentity.resolve(for: drive)
        serialIdentityKey = resolved.source == .smartSerial || resolved.source == .discoverySerial ? resolved.key : nil
        self.bootSessionID = bootSessionID; registryEntryID = drive.registryEntryID
        model = drive.model; sizeBytes = drive.sizeBytes; interconnect = drive.interconnect
    }
    public func matches(_ current: Self) -> Bool {
        if let serialIdentityKey { return serialIdentityKey == current.serialIdentityKey }
        guard let bootSessionID, bootSessionID == current.bootSessionID else { return false }
        return registryEntryID == current.registryEntryID && model == current.model
            && sizeBytes == current.sizeBytes && interconnect == current.interconnect
    }
    func validate(drive: DriveInfo) throws {
        guard registryEntryID == drive.registryEntryID, model == drive.model, sizeBytes == drive.sizeBytes,
              interconnect == drive.interconnect,
              serialIdentityKey == nil || serialIdentityKey?.range(of: "^drive:v2:serial:[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw MeasurementJournalError.invalidRecord
        }
    }
}
