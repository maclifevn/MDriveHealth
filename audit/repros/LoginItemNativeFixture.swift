/* Actual login control and onboarding, fake SDK/Settings actions. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import Observation
import Darwin

private struct NativeLoginError: LocalizedError {
    var errorDescription: String? { "Fixture: macOS refused registration" }
}
@MainActor @Observable private final class NativeLoginService: LoginItemManaging {
    var status: LoginItemStatus = .notRegistered
    var mode: String
    var requests: [Bool] = []
    var settingsOpens = 0
    var tourPresented = true
    init(mode: String) {
        self.mode = mode
        if mode == "enabled" { status = .enabled }
        if mode == "approval" { status = .requiresApproval }
        if mode == "notFound" { status = .notFound }
    }
    func setEnabled(_ enabled: Bool) async throws {
        requests.append(enabled)
        if mode == "busy" { try await Task.sleep(for: .seconds(60)) }
        if mode == "error" { throw NativeLoginError() }
        status = enabled ? (mode == "approval" ? .requiresApproval : .enabled) : .notRegistered
    }
    func openSettings() { settingsOpens += 1 }
}

private struct LoginFixtureView: View {
    @Bindable var service: NativeLoginService
    let controller: LoginItemController
    let tour: Bool
    let changed: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            if tour {
                Form {
                    Picker("Fake SDK response", selection: $service.mode) {
                        Text("Registration error").tag("error")
                        Text("Approval required").tag("approval")
                        Text("Enabled").tag("enabled")
                        Text("Delayed SDK operation").tag("busy")
                    }.accessibilityIdentifier("fixture.response")
                    HStack {
                        Button("Simulate OS approval") {
                            service.status = .enabled
                            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                            changed()
                        }.accessibilityIdentifier("fixture.approve")
                        Text("Requests: \(service.requests.count), Settings: \(service.settingsOpens)")
                    }
                }.formStyle(.grouped).frame(height: 145)
                ScrollView {
                    if service.tourPresented {
                        OnboardingView(isPresented: $service.tourPresented).environment(controller)
                    } else { Text("Onboarding completed") }
                }.frame(maxHeight: .infinity)
            } else {
                Form {
                    Section("Tự chạy khi đăng nhập") { LoginItemControl(controller: controller) }
                }.formStyle(.grouped).frame(width: 440)
            }
        }
        .onChange(of: controller.status) { changed() }
        .onChange(of: controller.errorMessage) { changed() }
        .onChange(of: controller.isBusy) { changed() }
        .onChange(of: service.settingsOpens) { changed() }
        .onChange(of: service.tourPresented) { changed() }
    }
}

@MainActor private final class LoginFixtureDelegate: NSObject, NSApplicationDelegate {
    let output: URL, mode: String, appearance: String
    let service: NativeLoginService, controller: LoginItemController
    var window: NSWindow!
    init(output: URL, mode: String, appearance: String) {
        self.output = output; self.mode = mode; self.appearance = appearance
        let service = NativeLoginService(mode: mode == "tour" ? "error" : mode)
        self.service = service; controller = LoginItemController(service: service)
    }
    func save() {
        let proof: [String: Any] = ["mode": mode, "preferredLocalizations": Bundle.main.preferredLocalizations,
            "requests": service.requests, "settingsOpens": service.settingsOpens, "sdkStatus": String(describing: service.status),
            "controllerStatus": String(describing: controller.status), "isBusy": controller.isBusy,
            "isRequested": controller.status.isRequested, "error": controller.errorMessage ?? "", "tourPresented": service.tourPresented,
            "realServiceManagementMutations": 0, "realSystemSettingsOpens": 0, "productionAppLaunched": false]
        try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("proof.json"), options: .atomic)
        if let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("view.png"))
        }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: mode == "tour" ? 520 : 440, height: mode == "tour" ? 760 : 420),
            styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "MDriveHealth login fixture"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: LoginFixtureView(service: service, controller: controller, tour: mode == "tour", changed: { [weak self] in self?.save() }))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if mode == "tour" { save(); return }
        Task { @MainActor in
            if mode == "error" || mode == "busy" { controller.setRequested(true) }
            if mode != "busy" { await controller.waitForCompletion() }
            try? await Task.sleep(for: .milliseconds(350))
            save(); Darwin.exit(0)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private struct LoginItemNativeFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count >= 4 else { Darwin.exit(64) }
        let mode = CommandLine.arguments[2], appearance = CommandLine.arguments[3]
        guard ["off","enabled","approval","error","notFound","busy","tour"].contains(mode), ["light","dark"].contains(appearance) else { Darwin.exit(64) }
        DispatchQueue.global().asyncAfter(deadline: .now() + (mode == "tour" ? 600 : 15)) { Darwin.exit(72) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = LoginFixtureDelegate(output: URL(fileURLWithPath: CommandLine.arguments[1]), mode: mode, appearance: appearance); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
