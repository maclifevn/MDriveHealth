/* Native AppKit shutdown fixture. Disposable data and fake hardware only. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import Darwin
@testable import MDriveHealthCore

private actor NativeMeasurements: MeasurementServing {
    let mode: String
    private(set) var entered = false
    private var released = false
    init(mode: String) { self.mode = mode }
    func release() { released = true }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        entered = true
        if mode != "unsaved" {
            while !cancelled() { try await Task.sleep(for: .milliseconds(5)) }
            cleaning(0)
            while !released { try await Task.sleep(for: .milliseconds(5)) }
            if mode == "cleanup" { throw BenchmarkError.cleanupFailed(path: "/fixture/owned-test") }
            throw BenchmarkError.cancelled
        }
        return .init(capturedAt: Date(timeIntervalSince1970: 1_700_000_000), volumeBSDName: volume.bsdName, volumeName: volume.name,
                     mountPoint: volume.mountPoint, fileSizeBytes: config.fileSizeBytes, sequentialBlockBytes: config.sequentialBlockBytes,
                     randomBlockBytes: config.randomBlockBytes, queueDepth: config.queueDepth,
                     sequentialWriteBytesPerSec: 1, sequentialReadBytesPerSec: 2, randomWriteBytesPerSec: nil, randomReadBytesPerSec: nil)
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult { throw BenchmarkError.cancelled }
}
private struct NativeHardware: DriveHardwareServing {
    func enumerate() async throws -> [DriveInfo] { [] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection { throw HardwareWorkerError.protocolViolation }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
}
private struct NativeScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}
@MainActor private final class NativeNotifications: NotificationDelivering {
    var calls = 0
    func access() async -> NotificationAccess { calls += 1; return .allowed }
    func requestPermission() async throws -> Bool { calls += 1; return true }
    func send(_ alert: DriveAlert) async throws { calls += 1 }
    func registeredRequestIDs() async -> Set<String> { [] }
}
@MainActor private final class NativeDelegate: NSObject, NSApplicationDelegate {
    let actual = AppDelegate()
    let output: URL, mode: String, suite: String, defaults: UserDefaults
    let hardware = NativeHardware(), notifications = NativeNotifications()
    let backend: NativeMeasurements
    let store: DriveStore, benchmark: BenchmarkRunner, capacity: CapacityVerifyRunner, monitor: MonitoringController
    var lifecycle: ApplicationLifecycle!
    var waitingTicks = 0, waitingLeaseHeld = false, launchCalls = 0, launchedAfterClose = false
    private func trace(_ message: String) {
        let path = output.appendingPathComponent("trace.log")
        let previous = (try? Data(contentsOf: path)) ?? Data()
        try? (previous + Data((message + "\n").utf8)).write(to: path)
    }
    init(output: URL, mode: String) throws {
        self.output = output; self.mode = mode
        suite = "com.maclife.mdrivehealth.lifecycle-fixture.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: SettingsKeys.monitoringEnabled)
        backend = NativeMeasurements(mode: mode)
        let database = output.appendingPathComponent("history.db"), unavailable = mode == "unsaved"
        store = DriveStore(history: HistoryAccess(factory: {
            if unavailable { throw HistoryError.unavailable }; return try HistoryStore(databaseURL: database)
        }), ioScanner: NativeScanner(), hardware: hardware)
        benchmark = BenchmarkRunner(store: store, worker: backend)
        capacity = CapacityVerifyRunner(store: store, worker: backend)
        monitor = MonitoringController(store: store, defaults: defaults, delivery: notifications, observePreferences: false)
        super.init()
        lifecycle = ApplicationLifecycle(store: store, monitor: monitor, benchmark: benchmark, capacity: capacity, launch: { [weak self] in
            guard let self else { throw HistoryError.unavailable }
            self.launchCalls += 1; self.launchedAfterClose = self.store.history.state == .closed && self.databaseFDs() == 0
        })
        actual.configure(lifecycle)
        actual.terminationReply = { [weak self] allowed in
            guard let self else { Darwin.exit(73) }
            Task { @MainActor in
                do {
                    if !allowed {
                        try await Task.sleep(for: .milliseconds(150)); try self.capture("failure")
                        let retainedID = self.benchmark.unsavedResults.first?.id
                        let reviewID = self.benchmark.workspaceReviews.first?.id
                        await self.lifecycle.resume(); self.benchmark.reset()
                        let retained = self.mode == "unsaved" ? self.benchmark.unsavedResults.first?.id == retainedID && retainedID != nil
                            : self.benchmark.workspaceReviews.first?.id == reviewID && reviewID != nil
                        try self.save(allowed: false, retainedAfterResumeAndReset: retained)
                        NSApp.reply(toApplicationShouldTerminate: false)
                        await self.monitor.shutdown(); self.store.beginShutdown()
                        await self.store.waitForBackgroundWork(); try await self.store.history.shutdown()
                        self.defaults.removePersistentDomain(forName: self.suite); Darwin.exit(retained ? 0 : 74)
                    } else {
                        try self.save(allowed: true, retainedAfterResumeAndReset: nil)
                        self.defaults.removePersistentDomain(forName: self.suite)
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                } catch { try? Data(error.localizedDescription.utf8).write(to: self.output.appendingPathComponent("failure.txt")); Darwin.exit(75) }
            }
        }
    }
    var drive: DriveInfo { .init(registryEntryID: UInt64(getpid()) << 32 | 271, bsdName: "disk999999", model: "Native fixture", serialNumber: "fixture",
        firmwareRevision: "F", sizeBytes: 1 << 40, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .unsupported) }
    func applicationDidFinishLaunching(_ notification: Notification) {
        trace("didFinishLaunching")
        Task { @MainActor in
            do {
                if mode != "unsaved" { try await store.history.connect() }
                let volume = VolumeUsage(bsdName: "disk999999s1", name: "Native fixture", mountPoint: output.path, totalBytes: 1 << 40, availableBytes: 1 << 40,
                    sharedCapacityKey: "disk999999s1", mountIdentity: MountedFilesystemIdentity.capture(at: output), writeIdentity: MountedFilesystemIdentity.capture(at: output), writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: output))
                benchmark.start(snapshot: .init(drive: drive), volume: volume, config: .init(fileSizeBytes: 16384, sequentialBlockBytes: 4096, includeRandomPhases: false))
                trace("benchmark started")
                while !(await backend.entered) { try await Task.sleep(for: .milliseconds(5)) }
                trace("measurement entered")
                if mode == "unsaved" { while benchmark.unsavedResults.isEmpty { try await Task.sleep(for: .milliseconds(5)) } }
                Task { @MainActor in
                    if self.mode != "unsaved" {
                        while !self.benchmark.isCleaning { try await Task.sleep(for: .milliseconds(5)) }
                        self.trace("cleaning published")
                        for _ in 0..<8 { self.waitingTicks += 1; try await Task.sleep(for: .milliseconds(30)) }
                        self.waitingLeaseHeld = (try? DriveCommandLock.acquire(registryEntryID: self.drive.id)) == nil
                        try self.capture("waiting"); await self.backend.release()
                    }
                }
                // Deliver the native action from a run-loop callback, as an
                // AppKit menu/button event does. A synchronous modal loop
                // inside an executing Swift Task would hold its executor.
                RunLoop.main.perform(inModes: [.default, .modalPanel]) { [self] in
                    MainActor.assumeIsolated {
                        self.trace("native termination requested")
                        if self.mode == "relaunch" { self.lifecycle.requestRelaunch() } else { NSApp.terminate(nil) }
                    }
                }
            } catch { try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("failure.txt")); Darwin.exit(76) }
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        trace("applicationShouldTerminate")
        let reply = actual.applicationShouldTerminate(sender); trace("delegate returned \(reply.rawValue)"); return reply
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { actual.applicationShouldTerminateAfterLastWindowClosed(sender) }
    private func databaseFDs() -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize() {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(descriptor, F_GETPATH, &path) == 0, String(cString: path).hasPrefix(output.appendingPathComponent("history.db").path) { count += 1 }
        }
        return count
    }
    private func capture(_ name: String) throws {
        guard let panel = NSApp.windows.first(where: { $0 is NSPanel }), let view = panel.contentView else { throw HistoryError.unavailable }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw HistoryError.unavailable }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // cacheDisplay contains translucent view pixels, not the panel's
        // backing. Composite against its native appearance for readable QA.
        guard let pixels = bitmap.cgImage,
              let context = CGContext(data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh, bitsPerComponent: 8,
                                      bytesPerRow: bitmap.pixelsWide * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw HistoryError.unavailable }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        panel.effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)!
            context.setFillColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: 1)
            context.fill(bounds)
        }
        context.draw(pixels, in: bounds)
        guard let composed = context.makeImage(), let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { throw HistoryError.unavailable }
        try png.write(to: output.appendingPathComponent(name + ".png"))
    }
    private func save(allowed: Bool, retainedAfterResumeAndReset: Bool?) throws {
        var proof: [String: Any] = ["mode": mode, "allowed": allowed, "historyClosedAtReply": store.history.state == .closed,
            "openDatabaseFDsAtReply": databaseFDs(), "mainActorTicksDuringTerminateLater": waitingTicks,
            "deviceLeaseHeldDuringCleanup": waitingLeaseHeld, "launchCalls": launchCalls, "launchedAfterHistoryClosed": launchedAfterClose,
            "notificationSDKCalls": notifications.calls, "fakeHardware": true, "measurementDataWrites": 0,
            "preferredLocalizations": Bundle.main.preferredLocalizations, "isReadyAtReply": lifecycle.isReady]
        if let retainedAfterResumeAndReset { proof["retainedAfterResumeAndReset"] = retainedAfterResumeAndReset }
        try JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("proof.json"))
    }
}
@main private struct LifecycleNativeFixture {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count >= 3 else { Darwin.exit(64) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2]
        guard ["quit", "relaunch", "unsaved", "cleanup"].contains(mode), FileManager.default.fileExists(atPath: output.path) else { Darwin.exit(64) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
            try? Data("Native terminateLater fixture timed out".utf8).write(to: output.appendingPathComponent("timeout.txt")); Darwin.exit(72)
        }
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = try NativeDelegate(output: output, mode: mode); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
