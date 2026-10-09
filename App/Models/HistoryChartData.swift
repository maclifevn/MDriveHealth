/* Exact history labels alongside approximate chart coordinates. GPL-3.0-or-later. */
import Foundation
import MDriveHealthCore

struct HistoryChartDatum: Identifiable {
    let date: Date
    let value: Double
    let label: String
    let isApproximate: Bool
    var id: Date { date }
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case temperature, score, lifetime, written, defects
    var id: String { rawValue }

    var title: String {
        switch self {
        case .temperature: return String(localized: "Nhiệt độ")
        case .score: return String(localized: "Điểm sức khoẻ")
        case .lifetime: return String(localized: "SSD lifetime")
        case .written: return String(localized: "Dữ liệu đã ghi")
        case .defects: return String(localized: "Bộ đếm lỗi")
        }
    }

    var unit: String {
        switch self {
        case .temperature: return "°C"
        case .score, .lifetime: return "%"
        case .written: return "TB"
        case .defects: return String(localized: "chart.unit.count", defaultValue: "số lượng")
        }
    }

    /// Labels retain the original integer. A Double chart coordinate must
    /// never be converted back to Int: valid UInt64 counters can overflow it
    /// or lose precision even when they are below Int.max.
    func datum(for point: HistoryPoint) -> HistoryChartDatum? {
        let value: Double, label: String
        var isApproximate = false
        switch self {
        case .temperature:
            guard let raw = point.temperatureC else { return nil }
            value = Double(raw); label = "\(raw)°C"
        case .score:
            guard let raw = point.healthScore else { return nil }
            value = Double(raw); label = "\(raw)/100"
        case .lifetime:
            guard let raw = point.lifetimeLeftPercent else { return nil }
            value = Double(raw); label = "\(raw)%"
        case .written:
            guard let raw = point.bytesWritten else { return nil }
            value = Double(raw) / 1e12
            label = String(format: "%.2f TB", value)
        case .defects:
            guard let raw = point.defectCount else { return nil }
            value = Double(raw); label = String(raw)
            isApproximate = UInt64(exactly: value) != raw
        }
        return HistoryChartDatum(date: point.capturedAt, value: value, label: label, isApproximate: isApproximate)
    }
}
