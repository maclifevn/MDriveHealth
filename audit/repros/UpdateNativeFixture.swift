/* Actual update view, fake responses and URL actions; no network/SDK side effects. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import Observation
import Darwin

@MainActor @Observable private final class UpdateFixtureState {
    var mode: String
    var calls = 0
    var opened: [String] = []
    let output: URL
    init(mode: String, output: URL) { self.mode = mode; self.output = output }
    func perform() async -> UpdateChecker.CheckResult {
        calls += 1; save()
        switch mode {
        case "interactive", "busy":
            do { try await Task.sleep(for: .seconds(60)); return .upToDate }
            catch { return .cancelled }
        case "available", "page":
            return .available(.init(version: "1.2.3", url: URL(string: "https://github.com/maclifevn/MDriveHealth/releases/tag/v1.2.3")!,
                downloadURL: mode == "page" ? nil : URL(string: "https://github.com/maclifevn/MDriveHealth/releases/download/v1.2.3/MDriveHealth-1.2.3.dmg")!))
        case "cancelled": return .cancelled
        case "latest": return .upToDate
        default: return .failed(.network)
        }
    }
    func save() {
        let proof: [String: Any] = ["mode": mode, "calls": calls, "openedURLs": opened, "networkCalls": 0,
            "preferredLocalizations": Bundle.main.preferredLocalizations, "productionAppLaunched": false]
        try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("proof.json"), options: .atomic)
    }
}

private struct UpdateFixtureView: View {
    @Bindable var state: UpdateFixtureState
    let controller: UpdateCheckController
    var body: some View {
        Form {
            if state.mode == "interactive" || state.mode == "latest" || state.mode == "available" || state.mode == "page" || state.mode == "failed" {
                Section("Fixture controls") {
                    Picker("Response", selection: $state.mode) {
                        Text("Delayed / cancel").tag("interactive")
                        Text("Installer available").tag("available")
                        Text("Release page only").tag("page")
                        Text("Network error").tag("failed")
                        Text("Latest version").tag("latest")
                    }.accessibilityIdentifier("fixture.response")
                    Text("Checks: \(state.calls), opened URLs: \(state.opened.count)")
                }
            }
            Section("Về MDriveHealth") {
                UpdateCheckView(controller: controller, openURL: { url in state.opened.append(url.absoluteString); state.save() })
            }
        }.formStyle(.grouped).frame(width: 440)
    }
}

@MainActor private final class UpdateFixtureDelegate: NSObject, NSApplicationDelegate {
    let state: UpdateFixtureState, appearance: String, interactive: Bool
    var window: NSWindow!
    let controller: UpdateCheckController
    init(output: URL, mode: String, appearance: String) {
        let state = UpdateFixtureState(mode: mode, output: output)
        self.state = state; self.appearance = appearance; interactive = mode == "interactive"
        controller = UpdateCheckController(operation: { await state.perform() })
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MDriveHealth update fixture"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: UpdateFixtureView(state: state, controller: controller))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        if interactive { state.save(); return }
        Task { @MainActor in
            controller.check()
            if state.mode != "busy" { await controller.waitForCompletion() }
            try? await Task.sleep(for: .milliseconds(350))
            state.save()
            guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { Darwin.exit(76) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { Darwin.exit(76) }
            do { try png.write(to: state.output.appendingPathComponent("view.png")) }
            catch { Darwin.exit(76) }
            Darwin.exit(0)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private struct UpdateNativeFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count >= 4 else { Darwin.exit(64) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2], appearance = CommandLine.arguments[3]
        guard ["interactive","available","page","failed","cancelled","busy","latest"].contains(mode), ["light","dark"].contains(appearance) else { Darwin.exit(64) }
        DispatchQueue.global().asyncAfter(deadline: .now() + (mode == "interactive" ? 600 : 15)) { Darwin.exit(72) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = UpdateFixtureDelegate(output: output, mode: mode, appearance: appearance); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
