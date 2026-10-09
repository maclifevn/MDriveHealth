/* AppKit termination bridge. MDriveHealth, GPL-3.0-or-later. */
import AppKit
import SwiftUI
import UserNotifications
import MDriveHealthCore

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var lifecycle: ApplicationLifecycle?
    private var requestedKind: ApplicationLifecycle.Kind = .quit
    private var terminationTask: Task<Void, Never>?
    private var panel: NSPanel?
    // Internal native-boundary injection for tests; production uses AppKit.
    var terminationReply: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    var terminateRequested: () -> Void = { NSApp.terminate(nil) }
    var statusPresented: ((ApplicationLifecycle) -> Void)?

    func configure(_ lifecycle: ApplicationLifecycle) {
        self.lifecycle = lifecycle
        lifecycle.exitRequested = { [weak self] kind in
            guard let self else { return }
            self.requestedKind = kind; self.terminateRequested()
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) { UNUserNotificationCenter.current().delegate = self }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let lifecycle else { return .terminateNow }
        if lifecycle.isReady { return .terminateNow }
        if terminationTask != nil { return .terminateLater }
        let kind = requestedKind
        lifecycle.begin(kind)
        presentStatus(lifecycle)
        terminationTask = Task { @MainActor [self] in
            let allowed = await lifecycle.prepare(kind)
            terminationTask = nil; requestedKind = .quit
            if allowed { panel?.orderOut(nil) } else { presentStatus(lifecycle) }
            terminationReply(allowed)
        }
        return .terminateLater
    }
    private func presentStatus(_ lifecycle: ApplicationLifecycle) {
        if let statusPresented { statusPresented(lifecycle); return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                                styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = String(localized: "lifecycle.title", defaultValue: "Đang chuẩn bị thoát")
            panel.isReleasedWhenClosed = false; panel.level = .modalPanel
            panel.contentView = NSHostingView(rootView: LifecycleStatusView(lifecycle: lifecycle) { [weak self] in self?.panel?.orderOut(nil) })
            panel.center(); self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.monitoringEnabled) else { return [] }
        return [.banner, .sound]
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        guard let key = userInfo["driveIdentityKey"] as? String, let url = DriveIdentity.notificationURL(forKey: key) else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
