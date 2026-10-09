/*
 * Components.swift — shared UI pieces: health badge, rings, stat cards.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import MDriveHealthCore

extension HealthRating {
    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .good: return "checkmark.circle.fill"
        case .ok: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .failing: return "exclamationmark.octagon.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

extension IssueSeverity {
    var displayName: String {
        switch self {
        case .info: return String(localized: "severity.info", defaultValue: "Thông tin")
        case .advisory: return String(localized: "severity.advisory", defaultValue: "Lưu ý")
        case .warning: return String(localized: "severity.warning", defaultValue: "Cảnh báo")
        case .critical: return String(localized: "severity.critical", defaultValue: "Nghiêm trọng")
        }
    }
}

struct HealthBadge: View {
    let rating: HealthRating

    var body: some View {
        Label(rating.displayName, systemImage: rating.systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(rating.badgeFill, in: Capsule())
            .accessibilityLabel(Text(verbatim: rating.displayName))
    }
}

/// Shared score presentation: missing scores never render as a perfect gauge.
struct HealthScoreGauge: View {
    let health: HealthReport
    var body: some View {
        RingGauge(value: health.score.map { Double($0) / 100 } ?? 0,
                  label: health.scoreDisplay, caption: "Sức khoẻ tổng thể",
                  color: health.rating.color)
    }
}

/// Circular gauge for scores/percentages.
struct RingGauge: View {
    let value: Double // 0...1
    let label: String
    let caption: Text
    var color: Color = .green

    @State private var animatedValue: Double = 0

    init(value: Double, label: String, caption: LocalizedStringKey, color: Color = .green) {
        self.value = value; self.label = label; self.caption = Text(caption); self.color = color
    }

    init(value: Double, label: String, captionText: String, color: Color = .green) {
        self.value = value; self.label = label; self.caption = Text(verbatim: captionText); self.color = color
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, animatedValue)))
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 12)
            }
            .frame(width: 92, height: 92)
            caption
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(Text(label))
        .onAppear {
            withAnimation(.easeOut(duration: 0.7)) { animatedValue = value }
        }
        .onChange(of: value) { _, newValue in
            withAnimation(.easeOut(duration: 0.4)) { animatedValue = newValue }
        }
    }
}

struct StatCard: View {
    let title: LocalizedStringKey
    let value: String
    var systemImage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption)
                }
                Text(title).font(.caption)
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shared card chrome: soft fill plus a hairline border — the border is
    /// what keeps card edges visible in dark mode, where a faint .quaternary
    /// fill alone melts into the window background.
    func cardBackground(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(.quaternary.opacity(0.35),
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
    }
}

enum Format {
    /// Shared instance — Format is only called from the main actor, and
    /// formatter construction is a classic per-frame allocation sink (bytes()
    /// runs dozens of times per render pass).
    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func hours(_ value: UInt64) -> String {
        if value >= 48 {
            return String(localized: "format.hours.days",
                          defaultValue: "\(value) giờ (≈\(value / 24) ngày)")
        }
        return String(localized: "format.hours", defaultValue: "\(value) giờ")
    }

    static func minutes(_ value: UInt64) -> String {
        String(localized: "format.minutes", defaultValue: "\(Int(clamping: value)) phút")
    }

    /// Throughput in decimal MB/s (1e6) — the disk-benchmark convention.
    /// locale-aware so vi gets its decimal comma like every other number.
    static func speed(_ bytesPerSecond: Double) -> String {
        BenchmarkDisplay.speed(bytesPerSecond)
    }

    static func iops(_ value: Double) -> String {
        BenchmarkDisplay.iops(value)
    }
}

/// Storage failures remain visible independently of SMART readings.
struct HistoryStorageBanner: View {
    let access: HistoryAccess
    let retry: () -> Void
    var body: some View {
        if access.state == .opening {
            HStack { ProgressView().controlSize(.small); Text("Đang mở dữ liệu lịch sử…"); Spacer() }.padding(10)
        } else if let issue = access.firstIssue {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusPalette.caution.foreground)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Lịch sử đang gặp lỗi").font(.headline)
                    Text(issue.message).font(.caption).textSelection(.enabled)
                    Text("Kết quả SMART hiện tại vẫn được hiển thị. Một số dữ liệu có thể chưa được lưu.").font(.caption)
                }
                Spacer()
                Button("Thử lại", action: retry)
            }.padding(10).background(.orange.opacity(0.10))
        }
    }
}

struct LegacyHistoryNotice: View {
    let access: HistoryAccess
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Dữ liệu từ phiên bản cũ được giữ riêng trong database vì cách định danh và diễn giải chỉ số đã thay đổi; không dùng cho biểu đồ hoặc cảnh báo mới.")
                .font(.caption).foregroundStyle(.secondary)
            if let backup = access.migrationBackupURL {
                Button("Hiện bản sao DB") { NSWorkspace.shared.activateFileViewerSelecting([backup]) }
            }
        }
    }
}
