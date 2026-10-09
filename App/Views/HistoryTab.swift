/*
 * HistoryTab.swift — trend charts (temperature, health, wear, defects).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import Charts
import MDriveHealthCore

struct HistoryTab: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store

    private enum Range: String, CaseIterable, Identifiable {
        case day = "24 giờ"
        case week = "7 ngày"
        case month = "30 ngày"
        case year = "1 năm"
        var id: String { rawValue }

        var interval: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .month: return 30 * 86_400
            case .year: return 365 * 86_400
            }
        }
    }

    @State private var metric: HistoryMetric = .temperature
    @State private var range: Range = .week
    @State private var points: [HistoryPoint] = []
    @State private var hoverDate: Date?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var loadedKey: String?
    @State private var requestID = UUID()
    /// Materialized from `points` on load/metric change — chartXSelection
    /// re-evaluates body on every pointer move while scrubbing, so this must
    /// not be recomputed per frame.
    @State private var chartData: [HistoryChartDatum] = []

    private var timeLabel: String { String(localized: "chart.axis.time", defaultValue: "Thời gian") }
    private var markerLabel: String { String(localized: "chart.axis.marker", defaultValue: "Mốc") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Chỉ số", selection: $metric) {
                        ForEach(HistoryMetric.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    .frame(maxWidth: 320)
                    Spacer()
                    Text("\(points.count) điểm dữ liệu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Picker("Khoảng", selection: $range) {
                    ForEach(Range.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            if chartData.contains(where: \.isApproximate) {
                Text("history.largeCounter.help")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !snapshot.identity.isPersistent {
                Label("Chưa định danh chắc chắn: lịch sử chỉ gắn với ổ trong phiên này, không tự nối qua lần khởi động hoặc cắm lại.", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let loadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Không đọc được lịch sử", systemImage: "exclamationmark.triangle")
                    Text(loadError).font(.caption).textSelection(.enabled)
                    Button("Thử lại") { Task { await store.retryHistory(); await reload() } }
                    if !points.isEmpty { Text("Đang hiển thị dữ liệu từ lần đọc trước.").font(.caption) }
                }.padding(10).background(.orange.opacity(0.10))
            }
            if isLoading && chartData.isEmpty {
                ProgressView("Đang đọc lịch sử…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if chartData.isEmpty && loadError == nil {
                if points.isEmpty {
                    ContentUnavailableView(
                        "Chưa có dữ liệu lịch sử",
                        systemImage: "chart.xyaxis.line",
                        description: Text(snapshot.drive.smartInterface == .unsupported
                            ? LocalizedStringKey("history.unsupported.help") : LocalizedStringKey("history.empty.help")))
                        .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "history.metricUnavailable.title",
                        systemImage: "questionmark.circle",
                        description: Text("history.metricUnavailable.help"))
                        .frame(maxHeight: .infinity)
                }
            } else if !chartData.isEmpty {
                Chart {
                    ForEach(chartData) { item in
                        LineMark(x: .value(timeLabel, item.date),
                                 y: .value(metric.title, item.value))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value(timeLabel, item.date),
                                 y: .value(metric.title, item.value))
                            .foregroundStyle(.linearGradient(
                                colors: [.accentColor.opacity(0.25), .clear],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(trendEvents) { event in
                        RuleMark(x: .value(markerLabel, event.date))
                            .foregroundStyle(event.color.opacity(0.65))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .leading,
                                        overflowResolution: .init(x: .fit(to: .plot), y: .disabled)) {
                                Text(event.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(event.color)
                            }
                    }
                    if let hovered = hoveredPoint {
                        RuleMark(x: .value(timeLabel, hovered.date))
                            .foregroundStyle(.secondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1))
                        PointMark(x: .value(timeLabel, hovered.date),
                                  y: .value(metric.title, hovered.value))
                            .symbolSize(60)
                            .annotation(
                                position: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart),
                                                          y: .disabled)
                            ) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(verbatim: hovered.label)
                                        .font(.caption.weight(.bold))
                                        .monospacedDigit()
                                    Text(hovered.date.formatted(
                                        date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(6)
                                .background(.regularMaterial,
                                            in: RoundedRectangle(cornerRadius: 6))
                            }
                    }
                }
                .chartYAxisLabel(metric.unit, position: .trailing)
                // Percent metrics anchor at 0; measurements (temp, TB, counts)
                // zoom to their actual range so small trends stay visible.
                .chartYScale(domain: .automatic(
                    includesZero: metric == .score || metric == .lifetime))
                .chartXSelection(value: $hoverDate)
                // Top rule annotations extend above the plot; reserve a row
                // so they do not touch the preceding status/help text.
                .padding(.top, 16)
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .task(id: "\(snapshot.identity.key)-\(range.rawValue)") { await reload() }
        .onChange(of: store.historyRevision) { Task { await reload() } }
        .onChange(of: metric) { hoverDate = nil; rebuildChartData() }
    }

    private func rebuildChartData() {
        chartData = points.compactMap { metric.datum(for: $0) }
    }

    /// Data point nearest to the hovered X position.
    private var hoveredPoint: HistoryChartDatum? {
        guard let hoverDate else { return nil }
        return chartData.min {
            abs($0.date.timeIntervalSince(hoverDate))
                < abs($1.date.timeIntervalSince(hoverDate))
        }
    }

    private struct TrendEvent: Identifiable {
        let id = UUID()
        let date: Date
        let title: LocalizedStringKey
        let color: Color
    }

    private var trendEvents: [TrendEvent] {
        guard points.count > 1 else { return [] }
        var events: [TrendEvent] = []
        var previous = points[0]
        for point in points.dropFirst() {
            if let old = previous.defectCount, let new = point.defectCount, new > old {
                events.append(.init(date: point.capturedAt, title: "Lỗi tăng", color: .red))
            }
            if let temp = point.temperatureC, temp >= 70,
               (previous.temperatureC ?? 0) < 70 {
                events.append(.init(date: point.capturedAt, title: "Nóng", color: .orange))
            }
            if let old = previous.healthScore, let new = point.healthScore, old - new >= 5 {
                events.append(.init(date: point.capturedAt, title: "Health giảm", color: .orange))
            }
            previous = point
        }
        return Array(events.prefix(12))
    }

    private func reload() async {
        let key = snapshot.identity.key, token = UUID()
        requestID = token
        isLoading = true
        defer { if requestID == token { isLoading = false } }
        if loadedKey != key { points = []; loadError = nil; rebuildChartData(); loadedKey = key }
        let since = Date().addingTimeInterval(-range.interval), bucket = max(1, range.interval / 1000)
        do {
            let result = try await store.history.run("snapshot.query:" + key) { try await $0.history(driveKey: key, since: since, bucketInterval: bucket) }
            guard requestID == token, !Task.isCancelled else { return }
            points = result; loadError = nil; rebuildChartData()
        } catch {
            guard requestID == token, !Task.isCancelled else { return }
            loadError = error.localizedDescription
        }
    }
}
