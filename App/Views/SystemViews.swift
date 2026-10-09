/*
 * SystemViews.swift — Battery / Sensors / Memory pages.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

/// Live-page polling loop: reload immediately, then every 5s until the
/// hosting `.task` is cancelled (view disappears).
@MainActor
private func periodicReload(_ reload: () async -> Void) async {
    await reload()
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        await reload()
    }
}

struct BatteryView: View {
    @Environment(DriveStore.self) private var store
    @State private var battery: BatteryInfo?

    @State private var readError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let readError { Text(readError).font(.caption).foregroundStyle(StatusPalette.caution.foreground) }
                if let battery {
                    HStack(spacing: 28) {
                        RingGauge(value: Double(battery.healthPercent) / 100,
                                  label: "\(battery.healthPercent)%",
                                  caption: "Sức khoẻ pin",
                                  color: battery.healthPercent > 79 ? .green :
                                         battery.healthPercent > 60 ? .orange : .red)
                        RingGauge(value: Double(battery.chargePercent) / 100,
                                  label: "\(battery.chargePercent)%",
                                  caption: battery.isCharging ? "Đang sạc" : "Mức pin",
                                  color: .blue)
                        if let temp = battery.temperatureCelsius {
                            RingGauge(value: min(1, temp / 60),
                                      label: String(format: "%.1f°C", temp),
                                      caption: "Nhiệt độ pin",
                                      color: temp >= 45 ? .orange : .teal)
                        }
                        Spacer()
                    }

                    let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]
                    LazyVGrid(columns: columns, spacing: 10) {
                        StatCard(title: "Chu kỳ sạc", value: "\(battery.cycleCount)",
                                 systemImage: "arrow.triangle.2.circlepath")
                        StatCard(title: "Dung lượng thiết kế",
                                 value: "\(battery.designCapacitymAh) mAh",
                                 systemImage: "battery.100")
                        StatCard(title: "Dung lượng hiện tại (full)",
                                 value: "\(battery.maxCapacitymAh) mAh",
                                 systemImage: "battery.75")
                        StatCard(title: "Nguồn ngoài",
                                 value: battery.externalPowerConnected ? "Đang cắm" : "Không",
                                 systemImage: "powerplug")
                        if let serial = battery.serialNumber {
                            StatCard(title: "Serial pin", value: serial, systemImage: "number")
                        }
                    }

                    if battery.healthPercent < 80 {
                        Label("Sức khoẻ pin dưới 80% — Apple khuyến nghị cân nhắc thay pin ở mức này.",
                              systemImage: "exclamationmark.triangle")
                            .padding(10)
                            .background(.orange.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                } else {
                    ContentUnavailableView("Không tìm thấy pin",
                                           systemImage: "battery.slash",
                                           description: Text("Máy Mac này không có pin (desktop) hoặc không đọc được thông tin pin."))
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Pin")
        .task { await periodicReload { await reload() } }
    }

    private func reload() async {
        do { let value = try await store.readBattery(); if !Task.isCancelled { battery = value; readError = nil } }
        catch { if !Task.isCancelled { readError = error.localizedDescription } }
    }
}

struct SensorsView: View {
    @Environment(\.locale) private var locale
    @Environment(DriveStore.self) private var store
    @State private var sensors: [TemperatureSensor] = []
    @State private var showAll = false

    @State private var readError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let readError { Text(readError).font(.caption).foregroundStyle(StatusPalette.caution.foreground) }
                if sensors.isEmpty {
                    ContentUnavailableView(
                        "Không đọc được cảm biến",
                        systemImage: "thermometer.medium.slash",
                        description: Text("Không truy cập được cảm biến nhiệt trên máy này."))
                } else {
                    let groups = SensorsReader.summarize(sensors)
                    HStack(spacing: 28) {
                        ForEach(groups.prefix(4), id: \.group) { item in
                            RingGauge(value: min(1, item.celsius / 100),
                                      label: String(format: "%.0f°C", item.celsius),
                                      captionText: item.group.displayName(locale: locale),
                                      color: item.celsius >= 80 ? .red :
                                             item.celsius >= 60 ? .orange : .teal)
                        }
                        Spacer()
                    }

                    Toggle("Hiện tất cả \(sensors.count) cảm biến", isOn: $showAll)
                    if showAll {
                        VStack(spacing: 0) {
                            ForEach(sensors) { sensor in
                                HStack {
                                    Text(sensor.name)
                                    Spacer()
                                    Text(String(format: "%.1f°C", sensor.celsius))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 5)
                                Divider()
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Cảm biến nhiệt")
        .task { await periodicReload { await reload() } }
    }

    private func reload() async {
        do { let value = try await store.readSensors(); if !Task.isCancelled { sensors = value; readError = nil } }
        catch { if !Task.isCancelled { readError = error.localizedDescription } }
    }
}

struct MemoryView: View {
    @Environment(DriveStore.self) private var store
    @State private var memory: MemoryStats?

    @State private var readError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let readError { Text(readError).font(.caption).foregroundStyle(StatusPalette.caution.foreground) }
                if let memory {
                    HStack(spacing: 28) {
                        RingGauge(value: memory.usedFraction,
                                  label: "\(Int(memory.usedFraction * 100))%",
                                  caption: "RAM đang dùng",
                                  color: pressureColor(memory.pressureLevel))
                        RingGauge(value: memory.swapTotalBytes > 0
                                    ? Double(memory.swapUsedBytes) / Double(memory.swapTotalBytes) : 0,
                                  label: Format.bytes(memory.swapUsedBytes),
                                  caption: "Swap đang dùng",
                                  color: .purple)
                        Spacer()
                    }

                    let columns = [GridItem(.adaptive(minimum: 170), spacing: 10)]
                    LazyVGrid(columns: columns, spacing: 10) {
                        StatCard(title: "Tổng RAM", value: Format.bytes(memory.totalBytes),
                                 systemImage: "memorychip")
                        StatCard(title: "App (active)", value: Format.bytes(memory.activeBytes),
                                 systemImage: "app.badge")
                        StatCard(title: "Wired (hệ thống)", value: Format.bytes(memory.wiredBytes),
                                 systemImage: "lock")
                        StatCard(title: "Đã nén", value: Format.bytes(memory.compressedBytes),
                                 systemImage: "archivebox")
                        StatCard(title: "Trống", value: Format.bytes(memory.freeBytes),
                                 systemImage: "circle.dashed")
                        StatCard(title: "Áp lực bộ nhớ", value: pressureLabel(memory.pressureLevel),
                                 systemImage: "gauge.medium")
                    }

                    if memory.pressureLevel >= 2 {
                        Label(memory.pressureLevel >= 4
                              ? "Áp lực bộ nhớ NGHIÊM TRỌNG — hãy đóng bớt ứng dụng."
                              : "Áp lực bộ nhớ cao — máy bắt đầu nén/swap nhiều.",
                              systemImage: "exclamationmark.triangle")
                            .padding(10)
                            .background(.orange.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Bộ nhớ")
        .task { await periodicReload { await reload() } }
    }

    private func reload() async {
        do { let value = try await store.readMemory(); if !Task.isCancelled { memory = value; readError = nil } }
        catch { if !Task.isCancelled { readError = error.localizedDescription } }
    }

    private func pressureColor(_ level: Int) -> Color {
        level >= 4 ? .red : level >= 2 ? .orange : .green
    }

    private func pressureLabel(_ level: Int) -> String {
        if level >= 4 { return String(localized: "pressure.critical", defaultValue: "Nghiêm trọng") }
        if level >= 2 { return String(localized: "pressure.high", defaultValue: "Cao") }
        return String(localized: "pressure.normal", defaultValue: "Bình thường")
    }
}
