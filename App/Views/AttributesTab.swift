/*
 * AttributesTab.swift — full SMART attribute table (ATA) / field list (NVMe).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct AttributesTab: View {
    let snapshot: DriveSnapshot

    var body: some View {
        switch snapshot.reading {
        case .ata(let reading):
            ATAAttributesTable(attributes: reading.attributes)
        case .nvme(let reading):
            NVMeFieldList(reading: reading)
        case nil:
            ContentUnavailableView("Không có dữ liệu SMART", systemImage: "questionmark.circle")
        }
    }
}

private struct ATAAttributesTable: View {
    let attributes: [ATAAttribute]

    var body: some View {
        Table(attributes) {
            TableColumn("ID") { attr in
                Text("\(attr.attributeID)").monospacedDigit()
            }
            .width(36)
            TableColumn("Thuộc tính") { attr in
                Text(attr.name.replacingOccurrences(of: "_", with: " "))
            }
            .width(min: 180)
            TableColumn("Giá trị") { attr in
                Text(attr.currentIsNormalized ? "\(attr.current)" : "—").monospacedDigit()
            }
            .width(50)
            TableColumn("Tệ nhất") { attr in
                Text(attr.worstIsNormalized ? "\(attr.worst)" : "—").monospacedDigit()
            }
            .width(56)
            TableColumn("Ngưỡng") { attr in
                Text(attr.threshold.map { "\($0)" } ?? "—").monospacedDigit()
            }
            .width(56)
            TableColumn("Loại") { attr in
                Text(attr.isPrefail ? "Pre-fail" : "Old-age")
                    .foregroundStyle(attr.isPrefail ? .orange : .secondary)
            }
            .width(64)
            TableColumn("Raw") { attr in
                Text(attr.rawDisplay).monospacedDigit()
            }
            TableColumn("Trạng thái") { attr in
                if attr.failedNow {
                    Label("HỎNG", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(StatusPalette.danger.foreground)
                } else if attr.failedEver {
                    Label("Từng hỏng", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(StatusPalette.caution.foreground)
                } else if !attr.hasComparableCurrent || !attr.hasComparableWorst || attr.threshold == nil || !attr.rawIsValid {
                    Label("Chưa xác định", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("OK", systemImage: "checkmark.circle")
                        .foregroundStyle(StatusPalette.positive.foreground)
                }
            }
            .width(90)
        }
    }
}

private struct NVMeFieldList: View {
    let reading: NVMeReading

    private var rows: [(String, String, Bool)] {
        let smart = reading.smart
        return [
            ("Critical Warning", String(format: "0x%02X", smart.criticalWarning.rawValue),
             !smart.criticalWarning.isEmpty),
            ("Composite Temperature", "\(smart.temperatureCelsius.map { "\($0)°C" } ?? "—")", false),
            ("Available Spare", "\(smart.availableSpare)%",
             smart.availableSpare < smart.availableSpareThreshold),
            ("Available Spare Threshold", "\(smart.availableSpareThreshold)%", false),
            ("Percentage Used", "\(smart.percentageUsed)%", smart.percentageUsed >= 90),
            ("Data Units Read", "\(smart.counterDisplay("dataUnitsRead")) (\(smart.bytesRead.map(Format.bytes) ?? "—"))", false),
            ("Data Units Written", "\(smart.counterDisplay("dataUnitsWritten")) (\(smart.bytesWritten.map(Format.bytes) ?? "—"))", false),
            ("Host Read Commands", "\(smart.counterDisplay("hostReadCommands"))", false),
            ("Host Write Commands", "\(smart.counterDisplay("hostWriteCommands"))", false),
            ("Controller Busy Time", smart.counterValue("controllerBusyTimeMinutes").map(Format.minutes) ?? "—", false),
            ("Power Cycles", "\(smart.counterDisplay("powerCycles"))", false),
            ("Power On Hours", "\(smart.counterDisplay("powerOnHours"))", false),
            ("Unsafe Shutdowns", "\(smart.counterDisplay("unsafeShutdowns"))", false),
            ("Media & Data Integrity Errors", "\(smart.counterDisplay("mediaErrors"))", (smart.knownMediaErrors ?? 0) > 0),
            ("Error Log Entries", "\(smart.counterDisplay("errorLogEntries"))", false),
        ]
    }

    var body: some View {
        List {
            Section("NVMe SMART / Health Information Log") {
                ForEach(rows, id: \.0) { name, value, highlight in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(value)
                            .monospacedDigit()
                            .foregroundStyle(highlight ? .red : .secondary)
                            .fontWeight(highlight ? .semibold : .regular)
                    }
                }
            }
            let sensors = reading.smart.temperatureSensorsKelvin.enumerated()
                .filter { $0.element > 0 }
            if !sensors.isEmpty {
                Section("Cảm biến nhiệt") {
                    ForEach(sensors.map { (index: $0.offset, kelvin: $0.element) },
                            id: \.index) { sensor in
                        HStack {
                            Text("Sensor \(sensor.index + 1)")
                            Spacer()
                            Text("\(Int(sensor.kelvin) - 273)°C")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}
