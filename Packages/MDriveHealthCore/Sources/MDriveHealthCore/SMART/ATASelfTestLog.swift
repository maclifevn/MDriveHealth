/* Validated physical self-test ring. MDriveHealth, GPL-3.0-or-later. */
import Foundation

public struct ATASelfTestLog: Sendable, Codable, Hashable {
    public let capturedAt: Date
    public let mostRecentSlot: Int
    public let entries: [ATASelfTestLogEntry]
    public var latest: ATASelfTestLogEntry? { entries.first }
    public init(capturedAt: Date, mostRecentSlot: Int, entries: [ATASelfTestLogEntry]) throws {
        self.capturedAt = capturedAt; self.mostRecentSlot = mostRecentSlot; self.entries = entries
        try validate()
    }
    public func validate() throws {
        guard capturedAt.timeIntervalSince1970.isFinite, (0...21).contains(mostRecentSlot), entries.count <= 21,
              (mostRecentSlot == 0 ? entries.isEmpty : (latest?.physicalSlot == mostRecentSlot && latest?.index == 1)) else {
            throw SMARTError.invalidPayload("self-test log header")
        }
        var seen = Set<Int>(), previousIndex = 0
        for entry in entries {
            guard let slot = entry.physicalSlot, (1...21).contains(slot), seen.insert(slot).inserted,
                  entry.index > previousIndex, entry.index == (mostRecentSlot - slot + 21) % 21 + 1,
                  entry.powerOnHours <= UInt16.max,
                  entry.failingLBA.map({ $0 <= UInt32.max && entry.statusCode == 7 }) ?? true,
                  !entry.inProgress || entry.percentRemaining <= 90 else { throw SMARTError.invalidPayload("self-test log descriptor") }
            previousIndex = entry.index
        }
    }
    /// Capture time and presentation order are not part of a record identity.
    public func sameRecord(as other: ATASelfTestLogEntry?, entry: ATASelfTestLogEntry) -> Bool {
        guard let other else { return false }
        return entry.physicalSlot == other.physicalSlot && entry.testType == other.testType && entry.statusByte == other.statusByte
            && entry.powerOnHours == other.powerOnHours && entry.failingLBA == other.failingLBA
    }
    public func sameContents(as other: ATASelfTestLog) -> Bool {
        mostRecentSlot == other.mostRecentSlot && entries.count == other.entries.count
            && entries.allSatisfy { entry in sameRecord(as: other.entries.first(where: { $0.physicalSlot == entry.physicalSlot }), entry: entry) }
    }
}
