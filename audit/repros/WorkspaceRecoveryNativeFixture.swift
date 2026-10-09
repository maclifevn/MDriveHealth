/* Native recovery UI, real private-file ownership, no real hardware actions. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import Darwin
@testable import MDriveHealthCore

private actor RecoveryUIHardware: DriveHardwareServing {
    let root: URL, mode: String
    private(set) var cleanups = 0
    init(root: URL, mode: String) { self.root = root; self.mode = mode }
    func enumerate() async throws -> [DriveInfo] { [] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection { throw HardwareWorkerError.protocolViolation }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan {
        let result = try DiskWorkspaceRecovery.scanFixture(at: root)
        return mode == "partial" ? .init(leftovers: result.leftovers, complete: false, diagnostic: "Fixture: incomplete scan", parentIdentity: result.parentIdentity) : result
    }
    func cleanupWorkspace(_ drive: DriveInfo, volume: VolumeUsage, leftover: DiskWorkspaceLeftover, lease: DriveCommandLock.Lease) async throws {
        cleanups += 1; try DiskWorkspaceRecovery.cleanupFixture(at: root, leftover: leftover)
    }
}
@MainActor private final class RecoveryUIDelegate: NSObject, NSApplicationDelegate {
    let output: URL, root: URL, mode: String, session = UUID()
    let operations = DriveOperations()
    let provider: RecoveryUIHardware
    let controller: WorkspaceRecoveryController
    var window: NSWindow!
    init(output: URL, mode: String) throws {
        self.output = output; self.mode = mode; root = output.appendingPathComponent("private-data")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside.txt"))
        provider = RecoveryUIHardware(root: root, mode: mode)
        controller = WorkspaceRecoveryController(operations: operations, hardware: provider)
        super.init()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run() }
            catch { try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("failure.txt")); Darwin.exit(76) }
        }
    }
    private func run() async throws {
        var workspace: DiskTestWorkspace? = try DiskTestWorkspace.fixture(at: root, sessionID: session)
        let path = workspace!.directoryURL, data = path.appendingPathComponent("data.bin")
        let fd = try workspace!.createFile("data.bin"), bytes = [UInt8](repeating: 0x71, count: 8192)
        guard bytes.withUnsafeBytes({ Darwin.write(fd, $0.baseAddress!, $0.count) }) == 8192 else { throw HistoryError.unavailable }; close(fd)
        let alias = root.appendingPathComponent("fixture-link")
        guard link(data.path, alias.path) == 0 else { throw HistoryError.unavailable }
        workspace = nil; guard unlink(alias.path) == 0 else { throw HistoryError.unavailable }
        if mode == "mixed" || mode == "partial" { try Data("legacy".utf8).write(to: root.appendingPathComponent(BenchmarkLocation.testFileName)) }
        let drive = DriveInfo(registryEntryID: UInt64(getpid()) << 32 | 613, bsdName: "disk999999", model: "UI fixture", serialNumber: "fixture", firmwareRevision: "F",
            sizeBytes: 1 << 40, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
        let volume = VolumeUsage(bsdName: "disk999999s1", name: "Fixture volume", mountPoint: root.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
            sharedCapacityKey: "fixture", mountIdentity: MountedFilesystemIdentity.capture(at: root), writeIdentity: MountedFilesystemIdentity.capture(at: root), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: root))
        let snapshot = DriveSnapshot(drive: drive, volumes: [volume])
        controller.updateFleet([snapshot]); await controller.waitForCompletion()
        let record = controller.records[0], name = DiskWorkspaceRecovery.workspaceName(for: session)
        let selection = controller.selection(recordID: record.id, name: name)
        var nativeButtonClicked = false, buttonTitles: [String] = []
        var nativeButtonRoute = "unavailable"
        if mode == "offline" { controller.updateFleet([]) }
        if mode == "cleaned" { guard let selection else { throw HistoryError.unavailable }; await controller.cleanup(selection) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: mode == "confirmation" ? 560 : 780, height: mode == "confirmation" ? 390 : 680),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Recovery fixture"; window.isReleasedWhenClosed = false
        if mode == "confirmation" {
            guard let selection else { throw HistoryError.unavailable }
            window.contentView = NSHostingView(rootView: WorkspaceCleanupConfirmation(controller: controller, selection: selection))
        } else {
            let reviews: [MeasurementWorkspaceReview] = mode == "cleaned" ? [] : [.init(id: session, drive: drive, volume: volume,
                message: String(localized: "lifecycle.cleanupUnconfirmed", defaultValue: "Cleanup unconfirmed"))]
            window.contentView = NSHostingView(rootView: WorkspaceRecoveryView(controller: controller, reviews: reviews))
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(450)); try capture("view")
        if mode == "confirmation" {
            let buttons = findButtons(window.contentView!)
            buttonTitles = buttons.map(\.title)
            if let button = buttons.first(where: { $0.title == String(localized: "recovery.confirmCleanup") }) {
                button.performClick(nil); nativeButtonClicked = true
                nativeButtonRoute = "NSButton bridge"
                for _ in 0..<200 { if await provider.cleanups > 0, !controller.isBusy { break }; try await Task.sleep(for: .milliseconds(10)) }
            }
            if !nativeButtonClicked, ProcessInfo.processInfo.environment["MDRIVE_NATIVE_UI_INTERACTIVE"] == "1" {
                // Only the fixture's actual SwiftUI button calls cleanup in
                // this mode. Wait for the accessibility-driven native action.
                while await provider.cleanups == 0 { try await Task.sleep(for: .milliseconds(50)) }
                await controller.waitForCompletion(); nativeButtonClicked = true; nativeButtonRoute = "native accessibility action"
            }
        }
        let cleanups = await provider.cleanups
        let proof: [String: Any] = ["mode": mode, "preferredLocalizations": Bundle.main.preferredLocalizations, "fakeHardware": true,
            "actualPrivateOwnershipScan": true, "nativeButtonClicked": nativeButtonClicked, "nativeButtonRoute": nativeButtonRoute, "nativeButtonTitles": buttonTitles,
            "cleanupCalls": cleanups, "ownedDataExistsAfter": FileManager.default.fileExists(atPath: data.path),
            "legacyDataPreserved": mode == "mixed" || mode == "partial" ? (try Data(contentsOf: root.appendingPathComponent(BenchmarkLocation.testFileName))) == Data("legacy".utf8) : true,
            "outsideSentinelPreserved": (try Data(contentsOf: root.appendingPathComponent("outside.txt"))) == Data("outside".utf8),
            "isCurrent": controller.records[0].isCurrent, "attached": controller.records[0].attached,
            "complete": controller.records[0].scan?.complete ?? false, "leftoverCount": controller.records[0].scan?.leftovers.count ?? 0,
            "measurementRangeBytes": 8192, "realHardwareMutations": 0, "notificationSDKCalls": 0]
        controller.beginShutdown(); await controller.waitForCompletion(); await operations.waitForIdle()
        let lock = try DriveCommandLock.acquire(registryEntryID: drive.id); lock.release()
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("proof.json"))
        Darwin.exit(0)
    }
    private func findButtons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(findButtons)
    }
    private func capture(_ name: String) throws {
        guard let view = window.contentView else { throw HistoryError.unavailable }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw HistoryError.unavailable }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let pixels = bitmap.cgImage, let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
            bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw HistoryError.unavailable }
        let rect = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
            context.setFillColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: 1); context.fill(rect)
        }
        context.draw(pixels, in: rect)
        guard let composed = context.makeImage(), let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { throw HistoryError.unavailable }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
}
@main private struct WorkspaceRecoveryNativeFixture {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 3 else { Darwin.exit(64) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2]
        guard ["mixed", "confirmation", "offline", "partial", "cleaned"].contains(mode) else { Darwin.exit(64) }
        let timeout: Double = ProcessInfo.processInfo.environment["MDRIVE_NATIVE_UI_INTERACTIVE"] == "1" ? 180 : 15
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { try? Data("Native recovery fixture timed out".utf8).write(to: output.appendingPathComponent("timeout.txt")); Darwin.exit(72) }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = try RecoveryUIDelegate(output: output, mode: mode); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
