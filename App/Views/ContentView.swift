/*
 * ContentView.swift — main split view: drive/system sidebar + detail.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct ContentView: View {
    @Environment(DriveStore.self) private var store
    @Environment(BenchmarkRunner.self) private var benchmark
    @Environment(CapacityVerifyRunner.self) private var capacity
    @State private var selection = SidebarSelection()
    // Loaded in .task — an initializer default would re-run the IOKit read on
    // every struct re-init and discard the result (@State keeps the first).
    @State private var battery: BatteryInfo?
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false
    @State private var showRecovery = false
    @State private var showMeasurementHistory = false
    @State private var showRecoveryAfterHistory = false

    var body: some View {
        VStack(spacing: 0) {
            statusBanners
            NavigationSplitView {
                sidebar
            } detail: {
                detail
            }
        }
        .toolbar {
            ToolbarItem {
                Button { showMeasurementHistory = true } label: { Label("measurementHistory.open", systemImage: "clock.arrow.circlepath") }
            }
            ToolbarItem {
                Button { showRecovery = true } label: { Label("recovery.open", systemImage: "folder.badge.questionmark") }
                    .help(store.workspaces.hasAttention
                          ? LocalizedStringKey("recovery.scanAttention.help")
                          : LocalizedStringKey("recovery.open"))
                    .accessibilityValue(Text(LocalizedStringKey(store.workspaces.hasAttention ? "recovery.scanAttention.help" : "")))
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Làm mới", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing || store.benchmarkInProgress || store.operations.isShuttingDown)
                .help(store.benchmarkInProgress
                      ? "Đang chạy phép đo — tạm dừng đọc SMART để không nhiễu kết quả"
                      : "Đọc lại SMART từ tất cả ổ đĩa")
            }
        }
        // Wait for fleet resolution before defaults or pending drive routing.
        .onChange(of: store.lastRefresh) { applyPendingSelectionOrDefault() }
        .onChange(of: store.visibleSnapshots.map(\.id)) { applyPendingSelectionOrDefault() }
        .onChange(of: store.isRefreshing) { if !store.isRefreshing { applyPendingSelectionOrDefault() } }
        .onChange(of: store.refreshError) { applyPendingSelectionOrDefault() }
        .onChange(of: battery != nil) { applyPendingSelectionOrDefault() }
        .onChange(of: store.pendingSelection, initial: true) { applyPendingSelectionOrDefault() }
        .onChange(of: store.pendingIdentitySelection, initial: true) { applyPendingSelectionOrDefault() }
        .alert("Không tìm thấy ổ liên quan", isPresented: Binding(get: { store.selectionError != nil }, set: { if !$0 { store.selectionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(store.selectionError ?? "") }
        .task {
            battery = try? await store.readBattery()
            if !hasSeenOnboarding { showOnboarding = true }
        }
        .sheet(isPresented: $showOnboarding, onDismiss: { hasSeenOnboarding = true }) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .sheet(isPresented: $showRecovery) {
            WorkspaceRecoveryView(controller: store.workspaces, reviews: benchmark.workspaceReviews + capacity.workspaceReviews + store.measurementRecovery.workspaceReviews)
        }
        .sheet(isPresented: $showMeasurementHistory, onDismiss: {
            if showRecoveryAfterHistory { showRecoveryAfterHistory = false; showRecovery = true }
        }) {
            MeasurementHistoryView(controller: store.measurementRecovery) { showRecoveryAfterHistory = true; showMeasurementHistory = false }
        }
        .onChange(of: store.lastRefresh) {
            Task { battery = try? await store.readBattery() }
        }
        // mdrivehealth://drive?key=<opaque identity> — notification taps.
        .onOpenURL { url in
            guard let key = DriveIdentity.notificationKey(from: url) else { return }
            store.pendingIdentitySelection = key
            NSApp.activate(ignoringOtherApps: true)
            applyPendingSelectionOrDefault()
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { selection.item }, set: { selection.choose($0) })) {
            Section {
                Label("Tất cả ổ đĩa", systemImage: "list.bullet.rectangle")
                    .tag(SidebarItem.allDrives)
            }
            if !store.internalDrives.isEmpty {
                Section("Ổ trong") {
                    ForEach(store.internalDrives) { snapshot in
                        DriveRow(snapshot: snapshot)
                            .tag(SidebarItem.drive(snapshot.id))
                    }
                }
            }
            if !store.externalDrives.isEmpty {
                Section("Ổ ngoài / khác") {
                    ForEach(store.externalDrives) { snapshot in
                        DriveRow(snapshot: snapshot)
                            .tag(SidebarItem.drive(snapshot.id))
                    }
                }
            }
            Section("Hệ thống") {
                if battery != nil {
                    Label("Pin", systemImage: batterySymbol)
                        .tag(SidebarItem.battery)
                }
                Label("Cảm biến nhiệt", systemImage: "thermometer.medium")
                    .tag(SidebarItem.sensors)
                Label("Bộ nhớ (RAM)", systemImage: "memorychip")
                    .tag(SidebarItem.memory)
            }
        }
        .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        .navigationTitle("MDriveHealth")
        .overlay {
            if store.snapshots.isEmpty && store.isRefreshing {
                ProgressView("Đang quét ổ đĩa…")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection.item {
        case .allDrives:
            DriveCompareView()
        case .drive(let id):
            if let snapshot = store.snapshots.first(where: { $0.id == id }) {
                DriveDetailView(snapshot: snapshot)
            } else {
                noSelection
            }
        case .battery:
            BatteryView()
        case .sensors:
            SensorsView()
        case .memory:
            MemoryView()
        case nil:
            noSelection
        }
    }

    private var statusBanners: some View {
        VStack(spacing: 0) {
            WorkspaceRecoveryBanner(controller: store.workspaces, reviewCount: benchmark.workspaceReviews.count + capacity.workspaceReviews.count) { showRecovery = true }
            if store.measurementRecovery.hasAttention {
                HStack {
                    Label("measurementHistory.attention", systemImage: "exclamationmark.triangle")
                    Spacer()
                    Button("measurementHistory.open") { showMeasurementHistory = true }
                }.font(.caption).padding(9).background(.quaternary)
            }
            HistoryStorageBanner(access: store.history) { Task { await store.retryHistory() } }
            if let error = store.refreshError {
                Text(error).font(.caption).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.10))
            }
        }
    }

    private func applyPendingSelectionOrDefault() {
        let settled = !store.isRefreshing && (store.lastRefresh != nil || store.refreshError != nil)
        if let key = store.pendingIdentitySelection {
            store.pendingSelection = nil
            if settled, let id = store.notificationTarget(for: key) {
                revealRequestedDrive(id)
                selection.choose(.drive(id)); store.pendingIdentitySelection = nil
            } else if settled {
                store.pendingIdentitySelection = nil
                store.selectionError = String(localized: "identity.notificationUnavailable", defaultValue: "Ổ đã ngắt kết nối hoặc chưa định danh chắc chắn. Thông báo cũ không được gán sang một ổ khác.")
            } else { return }
        }
        if let id = store.pendingSelection {
            switch selection.requestDrive(id, driveIDs: Set(store.snapshots.map(\.id)), discoverySettled: settled) {
            case .waiting: return
            case .selected:
                revealRequestedDrive(id)
                store.pendingSelection = nil
            case .unavailable:
                store.pendingSelection = nil
                store.selectionError = String(localized: "sidebar.driveUnavailable", defaultValue: "Ổ đã ngắt kết nối. Hãy chọn một ổ đang có trong thanh bên.")
            }
        }
        selection.reconcile(driveIDs: Set(store.visibleSnapshots.map(\.id)), batteryAvailable: battery != nil, discoverySettled: settled)
    }

    private func revealRequestedDrive(_ id: UInt64) {
        if store.snapshots.contains(where: { $0.id == id && $0.drive.isVirtual }) { store.showVirtualDrives = true }
    }

    /// Sidebar battery icon mirrors the real charge level.
    private var batterySymbol: String {
        guard let battery else { return "battery.100" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.chargePercent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var noSelection: some View {
        if let error = store.refreshError {
            ContentUnavailableView(
                "Không quét được ổ đĩa",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            ContentUnavailableView(
                "Chọn một mục",
                systemImage: "internaldrive",
                description: Text("Chọn ổ đĩa hoặc mục hệ thống ở thanh bên.")
            )
        }
    }
}

private struct DriveRow: View {
    let snapshot: DriveSnapshot

    var body: some View {
        HStack {
            Image(systemName: snapshot.drive.isInternal
                  ? "internaldrive.fill" : "externaldrive.fill")
                .foregroundStyle(snapshot.health?.rating.color ?? .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.drive.model)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(snapshot.drive.bsdName)
                    Text(Format.bytes(snapshot.drive.sizeBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let health = snapshot.health {
                Text(health.rating.displayName)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(health.rating.badgeFill, in: Capsule())
                    .help("\(health.rating.displayName) — \(health.scoreDisplay)/100")
            } else if snapshot.drive.smartInterface == .unsupported {
                Text("n/a")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("SMART không khả dụng qua \(snapshot.drive.interconnect)")
            }
        }
        .padding(.vertical, 2)
    }
}
