/*
 * MDriveHealthApp.swift — application entry point.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import UserNotifications
import MDriveHealthCore

@main
struct MDriveHealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: DriveStore
    @State private var monitor: MonitoringController
    @State private var benchmark: BenchmarkRunner
    @State private var capacityVerify: CapacityVerifyRunner
    @State private var lifecycle: ApplicationLifecycle
    @State private var loginItems: LoginItemController
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @AppStorage(SettingsKeys.menuBarDisplay) private var menuBarDisplay = MenuBarDisplay.icon

    init() {
        SettingsKeys.registerDefaults()
        let store = DriveStore()
        _store = State(initialValue: store)
        let monitor = MonitoringController(store: store), benchmark = BenchmarkRunner(store: store), capacity = CapacityVerifyRunner(store: store)
        let loginItems = LoginItemController()
        let lifecycle = ApplicationLifecycle(store: store, monitor: monitor, benchmark: benchmark, capacity: capacity, loginItems: loginItems)
        store.workspaces.onCompleteScan = { [weak benchmark, weak capacity, weak store] evidence in
            benchmark?.reconcileWorkspaceReviews(evidence); capacity?.reconcileWorkspaceReviews(evidence)
            store?.measurementRecovery.reconcile(evidence)
        }
        store.measurementRecovery.onNeedsWorkspaceScan = { [weak store] in store?.workspaces.requestScanAll() }
        _monitor = State(initialValue: monitor); _benchmark = State(initialValue: benchmark)
        _capacityVerify = State(initialValue: capacity); _lifecycle = State(initialValue: lifecycle)
        _loginItems = State(initialValue: loginItems)
        appDelegate.configure(lifecycle)
        store.measurementRecovery.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(store)
                .environment(benchmark)
                .environment(capacityVerify)
                .environment(monitor)
                .environment(lifecycle)
                .environment(loginItems)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    await monitor.start()
                    await store.refresh()
                }
        }
        .windowToolbarStyle(.unified)

        MenuBarExtra(isInserted: $showMenuBar) {
            MenuBarView()
                .environment(store)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(history: store.history)
                .environment(monitor)
                .environment(lifecycle)
                .environment(loginItems)
        }
    }

    private var menuBarLabel: some View {
        MenuBarStatusLabel(display: menuBarDisplay).environment(store)
    }
}
