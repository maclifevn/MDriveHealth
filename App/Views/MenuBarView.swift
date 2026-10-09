/*
 * MenuBarView.swift — menu bar quick status.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import MDriveHealthCore

struct MenuBarStatusLabel: View {
    @Environment(DriveStore.self) private var store
    let display: MenuBarDisplay
    var body: some View {
        let status = store.menuBarStatus
        HStack(spacing: 2) {
            Image(systemName: status.symbol)
            if let value = status.value(for: display) { Text(verbatim: value) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "MDriveHealth · " + status.accessibilityStatus))
        .accessibilityValue(Text(verbatim: status.value(for: display).map { display.accessibilityName + ": " + $0 } ?? ""))
        .help(status.isUnverified ? "menubar.unverifiedScope" : "menubar.scope")
    }
}

struct MenuBarView: View {
    @Environment(DriveStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var driveListHeight: CGFloat = 264

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusNotice

            if store.visibleSnapshots.isEmpty && store.refreshError == nil {
                emptyState
            } else if !store.visibleSnapshots.isEmpty {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.visibleSnapshots) { snapshot in
                            DriveMenuCard(snapshot: snapshot, readsPaused: store.benchmarkInProgress || store.operations.isShuttingDown) {
                                // Select the tapped drive in the main window.
                                store.pendingSelection = snapshot.id
                                openMainWindow()
                            }
                        }
                    }
                    .padding(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: DriveMenuListHeight.self, value: geometry.size.height)
                        }
                    }
                }
                // A max-only frame permits a tiny viewport after an empty
                // discovery. Preserve the rows' natural height up to the cap.
                .frame(height: min(driveListHeight, 264))
                .onPreferenceChange(DriveMenuListHeight.self) { height in
                    if height > 0 { driveListHeight = height }
                }
            }

            Divider()
            footer
        }
        .frame(width: 300)
    }

    private var header: some View {
        let status = store.menuBarStatus
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: status.symbol)
                    .font(.title2)
                    .foregroundStyle(statusColor(status))
                Text(verbatim: "MDriveHealth")
                    .font(.headline)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 2)
                if let worst = status.currentWorstRating, worst >= .warning {
                    HealthBadge(rating: worst).controlSize(.small)
                } else if status.isUnverified {
                    Text("menubar.unverified").font(.caption.weight(.semibold)).foregroundStyle(StatusPalette.caution.foreground)
                } else if let worst = status.currentWorstRating {
                    HealthBadge(rating: worst).controlSize(.small)
                }
            }
            Text(summarySubtitle).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.isUnverified, let worst = status.currentWorstRating, worst >= .warning {
                Text("menubar.unverified").font(.caption2).foregroundStyle(StatusPalette.caution.foreground)
            }
            Text(String.localizedStringWithFormat(String(localized: "menubar.currentCount", defaultValue: "SMART hiện tại: %lld/%lld ổ"),
                                                   status.currentSnapshots.count, status.snapshots.count))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func statusColor(_ status: MenuBarStatus) -> Color {
        if let rating = status.currentWorstRating, rating >= .warning { return rating.color }
        return status.isUnverified ? StatusPalette.caution.foreground : status.currentWorstRating?.color ?? .accentColor
    }

    @ViewBuilder private var statusNotice: some View {
        if let error = store.refreshError {
            VStack(alignment: .leading, spacing: 5) {
                Label("menubar.discoveryFailed", systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.semibold))
                Text(error).font(.caption).lineLimit(3).help(error)
                if !store.visibleSnapshots.isEmpty { Text("menubar.previousData").font(.caption2) }
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10))
        } else if store.benchmarkInProgress || store.operations.isShuttingDown {
            Text(store.operations.isShuttingDown ? "menubar.stopping" : "menubar.measurementPaused")
                .font(.caption).foregroundStyle(.secondary).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            Text(store.isRefreshing ? "Đang quét ổ đĩa…" : "Chưa phát hiện ổ đĩa")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(store.isRefreshing ? "Đang đọc SMART…" : "Làm mới",
                          systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!store.menuBarStatus.refreshEnabled)
                .help(store.benchmarkInProgress ? "menubar.measurementPaused" : "Đọc lại SMART từ tất cả ổ đĩa")
                .keyboardShortcut("r")

                Button {
                    openMainWindow()
                } label: {
                    Label("Mở", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("o")
            }
            .buttonStyle(.borderedProminent)

            HStack(spacing: 8) {
                SettingsLink {
                    Label("Cài đặt…", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(",")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Thoát", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.regular)
        .padding(12)
    }

    private var summarySubtitle: String {
        // "menubar.driveCount" carries plural variations (1 drive / n drives).
        let drives = String(localized: "menubar.driveCount",
                            defaultValue: "\(store.visibleSnapshots.count) ổ")
        let status: String
        if store.isRefreshing {
            status = String(localized: "menubar.readingShort", defaultValue: "đang đọc…")
        } else if store.refreshError != nil {
            status = String(localized: "menubar.unverified", defaultValue: "Chưa xác minh")
        } else if let last = store.lastRefresh {
            status = String(localized: "menubar.checkedAt",
                            defaultValue: "kiểm tra \(last.formatted(date: .omitted, time: .shortened))")
        } else {
            status = String(localized: "menubar.notChecked", defaultValue: "chưa kiểm tra")
        }
        return "\(drives) · \(status)"
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DriveMenuListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// One drive row in the menu bar popover.
private struct DriveMenuCard: View {
    let snapshot: DriveSnapshot
    let readsPaused: Bool
    let onTap: () -> Void
    private var readingState: MenuBarStatus.ReadingState { MenuBarStatus.readingState(snapshot, readsPaused: readsPaused) }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: dotColor.opacity(0.5), radius: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.drive.model)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(snapshot.drive.model)
                    HStack(spacing: 8) {
                        Text(snapshot.drive.bsdName)
                        if let temp = snapshot.reading?.temperatureCelsius {
                            Label("\(temp)°C", systemImage: "thermometer.medium")
                        }
                        if let life = snapshot.health?.lifetimeLeftPercent {
                            Label("\(life)%", systemImage: "bolt.heart")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    readingNotice
                }

                Spacer(minLength: 4)

                if let health = snapshot.health {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(readingState == .current ? health.rating.displayName : String.localizedStringWithFormat(
                            String(localized: "menubar.lastRating", defaultValue: "Trước: %@"), health.rating.displayName))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(health.rating.color)
                        Text("\(health.scoreDisplay)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Text(snapshot.drive.smartInterface == .unsupported ? "SMART n/a" : "menubar.unread")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .cardBackground(cornerRadius: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        let state = readingState
        return state == .current || state == .unsupported ? snapshot.health?.rating.color ?? StatusPalette.neutral.foreground : StatusPalette.caution.foreground
    }

    @ViewBuilder private var readingNotice: some View {
        switch readingState {
        case .current, .unsupported: EmptyView()
        case .reading: Text("menubar.readingShort").font(.caption2).foregroundStyle(.secondary)
        case .failed, .unread: Text("menubar.unread").font(.caption2).foregroundStyle(StatusPalette.caution.foreground)
        case .previous, .sleeping:
            let sleeping = readingState == .sleeping
            Text(snapshot.lastUpdated.map { date in
                String.localizedStringWithFormat(String(localized: sleeping ? "menubar.sleepingAt" : "menubar.cachedAt"),
                    date.formatted(date: .abbreviated, time: .shortened))
            } ?? String(localized: "menubar.previousData"))
                .font(.caption2).foregroundStyle(StatusPalette.caution.foreground).fixedSize(horizontal: false, vertical: true)
        }
        if let error = snapshot.lastError {
            Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2).help(error)
        }
    }
}
