// Synthetic UI evidence. Actual SelfTestTab/models, disposable DB, no hardware or notification SDK.
import AppKit
import SwiftUI
@testable import MDriveHealthCore

private struct FixtureScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}
private struct RenderHardware: DriveHardwareServing {
    let uncertain: Bool
    var supported = true
    let drive = DriveInfo(registryEntryID: 888888882, bsdName: "disk9999", model: "Synthetic ATA Drive", serialNumber: "RENDER-FIXTURE",
        firmwareRevision: "F", sizeBytes: 1000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
    func observation() throws -> SelfTestObservation {
        let reading = ATASMARTReading(capturedAt: Date(), identify: .init(model: drive.model, serialNumber: drive.serialNumber!, firmwareRevision: "F", rotationRate: 1),
            attributes: [], overallFailurePredicted: nil, selfTest: .init(rawByte: 0), driveFamily: nil, driveWarning: nil, selfTestSupported: supported)
        return .init(reading: reading, log: try .init(capturedAt: Date(), mostRecentSlot: 0, entries: []))
    }
    func enumerate() async throws -> [DriveInfo] { [drive] }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection { .init(reading: .ata(try observation().reading), skippedAsleep: false, volumes: []) }
    func validate(_ drive: DriveInfo) async throws {}
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { [] }
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation { try observation() }
    func dispatchSelfTest(_ drive: DriveInfo, command: SelfTestCommand, lease: DriveCommandLock.Lease) async throws -> SelfTestReceipt {
        if uncertain { throw SelfTestCommandError.uncertain("Synthetic lost ACK") }
        return .init(runID: command.runID, acceptedAt: Date())
    }
}
@main struct RenderSelfTestFixture {
    @MainActor private static func alignScrollViews(_ view: NSView) {
        if let scroll = view as? NSScrollView, let document = scroll.documentView {
            let y: CGFloat = document.isFlipped ? 0 : max(0, document.bounds.height - scroll.contentView.bounds.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
        for child in view.subviews { alignScrollViews(child) }
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("self-test-render-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        for mode in ["accepted", "unconfirmed", "indeterminate", "unsupported"] {
            let hardware = RenderHardware(uncertain: mode == "unconfirmed", supported: mode != "unsupported"), url = directory.appendingPathComponent(mode + ".db")
            let store = DriveStore(history: HistoryAccess(factory: { try HistoryStore(databaseURL: url) }), ioScanner: FixtureScanner(), hardware: hardware)
            await store.refresh()
            if mode != "unsupported" {
                do { try await store.startSelfTest(hardware.drive, extended: false) } catch { if mode != "unconfirmed" { throw error } }
            }
            if mode == "indeterminate" { _ = try await store.observeSelfTest(hardware.drive, closeWithoutResult: true) }
            let content = SelfTestTab(snapshot: store.snapshots[0]).environment(store)
                .frame(width: 760, height: 720).background(Color.white).preferredColorScheme(.light)
            // ScrollView is backed by AppKit and ImageRenderer omits it.
            // Cache the actual native hosting view in an off-screen window.
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 760, height: 720),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            alignScrollViews(host); host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: output.appendingPathComponent(mode + ".png"))
            window.orderOut(nil)
        }
        print("Rendered actual self-test UI: accepted, unconfirmed ACK, indeterminate completion, unsupported capability")
    }
}
