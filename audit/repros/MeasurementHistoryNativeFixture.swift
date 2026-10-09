/* Native recovery/history rendering on private disposable files. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import Darwin
@testable import MDriveHealthCore

@MainActor private final class HistoryUIDelegate: NSObject, NSApplicationDelegate {
    let output: URL, mode: String, appearance: String
    var window: NSWindow!
    init(output: URL, mode: String, appearance: String) { self.output = output; self.mode = mode; self.appearance = appearance }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch { try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("failure.txt")); Darwin.exit(76) }
        }
    }
    private func run() async throws {
        let root = output.appendingPathComponent("private-data"), journalURL = root.appendingPathComponent("journal"), database = root.appendingPathComponent("history.db")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
        let drive = DriveInfo(registryEntryID: UInt64(getpid()) << 32 | 729, bsdName: "disk999996", model: "Disconnected fixture drive", serialNumber: "native-history-fixture",
            firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999996s1", name: "Private fixture volume", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
            sharedCapacityKey: "fixture", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        let config = BenchmarkConfig(fileSizeBytes: 8192, sequentialBlockBytes: 4096, includeRandomPhases: false)
        let journal = try MeasurementJournal(rootURL: journalURL)
        let history = HistoryAccess(factory: { try HistoryStore(databaseURL: database) })
        let recovery = MeasurementRecoveryController(history: history, service: SystemMeasurementRecovery(rootURL: journalURL))
        let intent = MeasurementJobIntent(drive: drive, driveKey: DriveIdentity.resolve(for: drive).key, volume: volume,
            operation: .benchmark(config), historyPolicy: mode == "omitted" ? .omit : .archive)
        var lease: MeasurementJobLease? = try journal.prepare(intent)
        if mode != "interrupted" {
            let result = try DiskBenchmarkEngine().run(in: root, volume: volume, config: config, isCancelled: { false }, progress: { _ in }, measurementID: intent.id, cleanupProgress: { _ in })
            let terminal = MeasurementJobTerminal(intent: intent, outcome: .benchmark(result))
            if mode == "unverified" {
                let record = MeasurementJobRecord(intent: intent, terminal: terminal)
                _ = try await history.run("fixture.commit") { try await $0.recordMeasurement(record) }
                let path = journalURL.appendingPathComponent("job-" + intent.id.uuidString).appendingPathComponent("terminal.json")
                try Data("foreign metadata".utf8).write(to: path); guard chmod(path.path, 0o600) == 0 else { throw POSIXError(.EIO) }
            } else { try lease!.writeTerminal(terminal) }
        }
        lease = nil
        if mode == "archived" {
            let config = CapacityVerifyConfig(reserveBytes: 1 << 20, fileSizeBytes: 8192, blockBytes: 4096, maxBytes: 16384, dataRiskAcknowledged: true)
            let intent = MeasurementJobIntent(drive: drive, driveKey: DriveIdentity.resolve(for: drive).key, volume: volume, operation: .capacity(config))
            let lease = try journal.prepare(intent)
            let result = try CapacityVerifier().run(in: root, volume: volume, config: config, isCancelled: { false }, progress: { _ in }, measurementID: intent.id, cleanupProgress: { _ in })
            try lease.writeTerminal(.init(intent: intent, outcome: .capacity(result)))
        }
        recovery.start(); await recovery.waitForCompletion()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Measurement history fixture"; window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentView = NSHostingView(rootView: MeasurementHistoryView(controller: recovery, openWorkspaces: {}))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(350)); try capture()
        let proof: [String: Any] = ["mode": mode, "appearance": appearance, "preferredLocalizations": Bundle.main.preferredLocalizations,
            "jobs": recovery.jobs.count, "archived": recovery.archivedRecords.count, "reviews": recovery.workspaceReviews.count,
            "unverified": recovery.jobs.contains(where: { $0.state == .unverified }), "omitted": recovery.jobs.contains(where: { $0.intent?.historyPolicy == .omit }),
            "outsideSentinelPreserved": try Data(contentsOf: root.appendingPathComponent("outside.txt")) == Data("outside".utf8),
            "realHardwareMutations": 0, "notificationSDKCalls": 0, "nativeButtonClicks": 0, "maximumFixtureBytes": 16384]
        recovery.beginShutdown(); await recovery.waitForCompletion(); try await history.shutdown()
        try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys, .prettyPrinted]).write(to: output.appendingPathComponent("proof.json"))
        Darwin.exit(0)
    }
    private func capture() throws {
        guard let view = window.contentView else { throw HistoryError.unavailable }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw HistoryError.unavailable }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let pixels = bitmap.cgImage, let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw HistoryError.unavailable }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
            context.setFillColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        }
        context.draw(pixels, in: CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw HistoryError.unavailable }
        try png.write(to: output.appendingPathComponent("view.png"))
    }
}
@main private struct MeasurementHistoryNativeFixture {
    @MainActor static func main() {
        guard CommandLine.arguments.count >= 4 else { Darwin.exit(64) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2], appearance = CommandLine.arguments[3]
        guard ["archived", "interrupted", "omitted", "unverified"].contains(mode), ["light", "dark"].contains(appearance) else { Darwin.exit(64) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { Darwin.exit(72) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = HistoryUIDelegate(output: output, mode: mode, appearance: appearance); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
