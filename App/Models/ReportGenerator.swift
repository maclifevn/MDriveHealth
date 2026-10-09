/*
 * ReportGenerator.swift — plain-text drive report for sharing/support.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

/// Builds the text report users copy into community posts when asking for
/// help — everything a helper needs to assess the drive at a glance.
enum ReportGenerator {
    static func text(for snapshot: DriveSnapshot, ioErrors24h: Int?,
                     latestBenchmark: BenchmarkResult? = nil) -> String {
        var lines: [String] = []
        let drive = snapshot.drive

        lines.append("═══════ MDriveHealth — \(String(localized: "report.title", defaultValue: "Báo cáo ổ đĩa")) ═══════")
        lines.append(String(localized: "report.generatedAt",
                            defaultValue: "Tạo lúc: \(Date().formatted(date: .abbreviated, time: .shortened)) · MDriveHealth \(UpdateChecker.currentVersion)"))
        lines.append("")

        lines.append(label(String(localized: "report.drive", defaultValue: "Ổ đĩa")) + drive.model)
        lines.append(label(String(localized: "report.bus", defaultValue: "Kết nối")) + "\(drive.bsdName) · \(drive.interconnect) (\(drive.location))")
        lines.append(label(String(localized: "report.kind", defaultValue: "Loại"))
            + "\(drive.isSolidState ? "SSD" : "HDD") · \(Format.bytes(drive.sizeBytes))"
            + (drive.isInternal
                ? " · " + String(localized: "report.internal", defaultValue: "ổ trong")
                : " · " + String(localized: "report.external", defaultValue: "ổ ngoài")))
        if let serial = drive.serialNumber {
            // Masked: this report is written to be pasted into public
            // community posts — a full serial enables warranty fraud.
            lines.append(label(String(localized: "report.serial", defaultValue: "Serial"))
                + maskedSerial(serial))
        }
        if let firmware = drive.firmwareRevision {
            lines.append(label(String(localized: "report.firmware", defaultValue: "Firmware")) + firmware)
        }
        lines.append("")

        // Health.
        lines.append(section(String(localized: "report.health", defaultValue: "SỨC KHOẺ")))
        if let health = snapshot.health {
            lines.append(label(String(localized: "report.score", defaultValue: "Điểm"))
                + "\(health.scoreDisplay)/100 (\(health.rating.displayName))")
            lines.append(health.coverageDescription)
            if let lifetime = health.lifetimeLeftPercent {
                lines.append(label(String(localized: "report.lifetime", defaultValue: "SSD lifetime"))
                    + String(localized: "report.lifetimeLeft", defaultValue: "còn \(lifetime)%"))
            }
            if let reading = snapshot.reading {
                if let temp = reading.temperatureCelsius {
                    lines.append(label(String(localized: "report.temperature", defaultValue: "Nhiệt độ")) + "\(temp)°C")
                }
                if let hours = reading.powerOnHours {
                    lines.append(label(String(localized: "report.powerOn", defaultValue: "Power-on")) + Format.hours(hours))
                }
                if let written = reading.bytesWritten {
                    lines.append(label(String(localized: "report.written", defaultValue: "Đã ghi")) + Format.bytes(written))
                }
                if let defects = reading.dangerousDefectTotal, defects > 0 {
                    lines.append(label(String(localized: "report.defects", defaultValue: "Defect/pending")) + "\(defects)")
                }
            }
            if let stale = snapshot.lastUpdated, snapshot.isStale {
                lines.append(String(localized: "report.stale",
                                    defaultValue: "⚠ Dữ liệu từ lần đọc \(stale.formatted(date: .abbreviated, time: .shortened)); trạng thái hiện tại chưa được xác minh."))
            }
            lines.append("")
            lines.append(section(String(localized: "report.issues", defaultValue: "CHỈ BÁO")))
            if health.issues.isEmpty {
                lines.append(String(localized: "report.noIssues",
                                    defaultValue: "Không phát hiện vấn đề trong các chỉ số được hỗ trợ."))
            } else {
                for issue in health.issues {
                    lines.append("[\(issue.severity.displayName)] \(issue.title)")
                    lines.append("    \(issue.detail)")
                }
            }
        } else if snapshot.drive.smartInterface == .unsupported {
            lines.append(String(localized: "report.noSmart",
                                defaultValue: "SMART chưa khả dụng qua giao diện hiện tại. Hỗ trợ phụ thuộc thiết bị, bridge và driver; thiếu SMART không tự chứng minh ổ bị lỗi."))
        } else if let error = snapshot.lastError {
            lines.append(String(localized: "report.readError",
                                defaultValue: "Không đọc được SMART: \(error)"))
        }
        if let ioErrors24h, ioErrors24h > 0 {
            lines.append(String(localized: "report.ioErrors",
                                defaultValue: "⚠ \(ioErrors24h) lỗi I/O trong kernel log 24 giờ qua"))
        }
        lines.append("")

        // Capacity.
        if !snapshot.volumes.isEmpty {
            lines.append(section(String(localized: "report.capacity", defaultValue: "DUNG LƯỢNG")))
            for group in VolumeUsageReader.capacityGroups(snapshot.volumes) {
                lines.append("\(group.displayName): \(Format.bytes(group.usedBytes)) / \(Format.bytes(group.totalBytes)) (\(Int(group.usedFraction * 100))%)")
            }
            lines.append("")
        }

        // Benchmark.
        if let benchmark = latestBenchmark {
            lines.append(section(String(localized: "report.speed", defaultValue: "TỐC ĐỘ (benchmark)")))
            lines.append(label(String(localized: "report.speed.when", defaultValue: "Đo lúc"))
                + "\(benchmark.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(benchmark.volumeName) · \(Format.bytes(benchmark.fileSizeBytes))")
            lines.append(label(String(localized: "report.speed.seq", defaultValue: "Tuần tự"))
                + "Ghi \(Format.speed(benchmark.sequentialWriteBytesPerSec)) · Đọc \(Format.speed(benchmark.sequentialReadBytesPerSec))")
            if let rw = benchmark.randomWriteBytesPerSec, let rr = benchmark.randomReadBytesPerSec {
                lines.append(label(String(localized: "report.speed.rand", defaultValue: "Random 4K"))
                    + "Ghi \(Format.speed(rw)) (\(Format.iops(benchmark.randomWriteIOPS ?? 0))) · Đọc \(Format.speed(rr)) (\(Format.iops(benchmark.randomReadIOPS ?? 0)))")
            }
            lines.append("")
        }

        // Raw SMART data.
        switch snapshot.reading {
        case .ata(let reading):
            lines.append(section(String(localized: "report.attributes", defaultValue: "THUỘC TÍNH SMART")))
            lines.append(pad("ID", 4) + pad("Name", 26) + pad("Val", 5)
                + pad("Wor", 5) + pad("Thr", 5) + pad("Type", 9) + "Raw")
            for attribute in reading.attributes {
                lines.append(pad("\(attribute.attributeID)", 4)
                    + pad(String(attribute.name.prefix(25)), 26)
                    + pad(attribute.currentIsNormalized ? "\(attribute.current)" : "—", 5)
                    + pad(attribute.worstIsNormalized ? "\(attribute.worst)" : "—", 5)
                    + pad(attribute.threshold.map { "\($0)" } ?? "—", 5)
                    + pad(attribute.isPrefail ? "Pre-fail" : "Old-age", 9)
                    + attribute.rawDisplay)
            }
        case .nvme(let reading):
            lines.append(section(String(localized: "report.nvmeLog", defaultValue: "NVMe SMART / HEALTH LOG")))
            let smart = reading.smart
            lines.append("Critical Warning       : " + String(format: "0x%02X", smart.criticalWarning.rawValue))
            lines.append("Composite Temperature  : \(smart.temperatureCelsius.map { "\($0)°C" } ?? "—")")
            lines.append("Available Spare        : \(smart.availableSpare)% (threshold \(smart.availableSpareThreshold)%)")
            lines.append("Percentage Used        : \(smart.percentageUsed)%")
            lines.append("Data Read / Written    : \(smart.bytesRead.map(Format.bytes) ?? "—") / \(smart.bytesWritten.map(Format.bytes) ?? "—")")
            lines.append("Power Cycles / Hours   : \(smart.counterDisplay("powerCycles")) / \(smart.counterDisplay("powerOnHours"))")
            lines.append("Unsafe Shutdowns       : \(smart.counterDisplay("unsafeShutdowns"))")
            lines.append("Media Errors           : \(smart.counterDisplay("mediaErrors"))")
            lines.append("Error Log Entries      : \(smart.counterDisplay("errorLogEntries"))")
        case nil:
            break
        }

        lines.append("")
        lines.append(String(localized: "report.footer",
                            defaultValue: "— Tạo bởi MDriveHealth, công cụ mã nguồn mở miễn phí cho cộng đồng Maclife —"))
        return lines.joined(separator: "\n")
    }

    private static func maskedSerial(_ serial: String) -> String {
        serial.count > 4 ? "••••" + serial.suffix(4) : serial
    }

    private static func section(_ title: String) -> String {
        "── \(title) ──"
    }

    private static func label(_ title: String) -> String {
        pad(title, 12) + ": "
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " "
            : text + String(repeating: " ", count: width - text.count)
    }
}
