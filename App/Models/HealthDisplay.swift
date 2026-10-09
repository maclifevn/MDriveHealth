/* Labels shared by notifications and views. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import MDriveHealthCore

extension HealthRating {
    var displayName: String {
        switch self {
        case .unknown: return String(localized: "rating.unknown", defaultValue: "Chưa xác định")
        case .good: return String(localized: "rating.good", defaultValue: "Tốt")
        case .ok: return String(localized: "rating.ok", defaultValue: "Ổn")
        case .warning: return String(localized: "rating.warning", defaultValue: "Cảnh báo")
        case .failing: return String(localized: "rating.failing", defaultValue: "Đang hỏng")
        case .failed: return String(localized: "rating.failed", defaultValue: "Hỏng")
        }
    }
}

enum SelfTestDisplay {
    /// A failed log read leaves the last validated observation cached. A newer
    /// SMART snapshot must still drive current status/capability presentation.
    static func latestReading(snapshot: DriveReading?, observation: ATASMARTReading?) -> ATASMARTReading? {
        guard case .ata(let snapshotReading) = snapshot else { return observation }
        guard let observation, observation.capturedAt >= snapshotReading.capturedAt else { return snapshotReading }
        return observation
    }
}
