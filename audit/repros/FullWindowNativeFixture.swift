/* Production windows/views with private history and fake hardware/SDK. GPL-3.0-or-later. */
import AppKit
import SwiftUI
import Observation
import Darwin
@testable import MDriveHealthCore

private actor WindowHardware: DriveHardwareServing {
    let volumeRoot: URL
    init(volumeRoot: URL) { self.volumeRoot = volumeRoot }
    var mode = "fleet"
    var calls: [String: Int] = [:]
    let drives = [
        DriveInfo(registryEntryID: 101, bsdName: "disk101", model: "Fixture Internal NVMe", serialNumber: "NATIVE-INTERNAL", firmwareRevision: "F1", sizeBytes: 500_000_000_000, interconnect: "PCIe", location: "Internal", isSolidState: true, smartInterface: .nvme),
        DriveInfo(registryEntryID: 102, bsdName: "disk102", model: "Fixture External NVMe", serialNumber: "NATIVE-EXTERNAL", firmwareRevision: "F2", sizeBytes: 1_000_000_000_000, interconnect: "Thunderbolt", location: "External", isSolidState: true, smartInterface: .nvme),
        DriveInfo(registryEntryID: 103, bsdName: "disk103", model: "Fixture USB Unknown", serialNumber: "NATIVE-USB", firmwareRevision: "F3", sizeBytes: 128_000_000_000, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported),
        DriveInfo(registryEntryID: 104, bsdName: "disk104", model: "Fixture SATA SSD", serialNumber: "NATIVE-ATA", firmwareRevision: "F4", sizeBytes: 256_000_000_000, interconnect: "SATA", location: "External", isSolidState: true, smartInterface: .ata)
    ]
    func set(_ mode: String) { self.mode = mode }
    func count(_ name: String) { calls[name, default: 0] += 1 }
    func enumerate() async throws -> [DriveInfo] {
        count("enumerate")
        try await Task.sleep(for: .milliseconds(300))
        if mode == "failed" { throw HardwareWorkerError.remote("Fixture discovery failed; prior fleet retained") }
        if mode == "longFailure" {
            throw HardwareWorkerError.remote(Array(repeating: "Fixture discovery failed. The device worker could not confirm the current attachment; previous readings are retained for review.", count: 7).joined(separator: " "))
        }
        if mode == "empty" { return [] }
        if mode == "single" { return [drives[0]] }
        if mode == "many" {
            return (201...212).map { id in
                DriveInfo(registryEntryID: UInt64(id), bsdName: "disk\(id)", model: "Fixture NVMe \(id)",
                          serialNumber: "NATIVE-MANY-\(id)", firmwareRevision: "F1", sizeBytes: 500_000_000_000,
                          interconnect: "Thunderbolt", location: "External", isSolidState: true, smartInterface: .nvme)
            }
        }
        if mode == "disconnected" { return [drives[0], drives[2]] }
        return CommandLine.arguments.contains("--omit-ata") ? Array(drives.prefix(3)) : drives
    }
    func inspect(_ drive: DriveInfo, avoidWakingIdle: Bool) async throws -> HardwareInspection {
        count("inspect")
        let volumes = try volumes(drive)
        if mode == "criticalPartial" && drive.id == 101 { throw HardwareWorkerError.remote("Fixture internal SMART unavailable; external reading has a critical warning") }
        if mode == "probeFailure" { throw HardwareWorkerError.remote("Fixture SMART read failed; no hardware was accessed") }
        if mode == "sleeping" { return .init(reading: nil, skippedAsleep: true, volumes: volumes) }
        if drive.smartInterface == .unsupported { return .init(reading: nil, skippedAsleep: false, volumes: volumes) }
        if drive.smartInterface == .ata { return .init(reading: .ata(ataReading(drive)), skippedAsleep: false, volumes: volumes) }
        let sample = MockData.nvmeReading(percentageUsed: drive.id == 102 ? 35 : 4,
                                        criticalWarning: mode == "criticalPartial" && drive.id == 102 ? [.mediaReadOnly] : [])
        let controller = NVMeControllerInfo(model: drive.model, serialNumber: drive.serialNumber ?? "", firmwareRevision: drive.firmwareRevision ?? "", ieeeOUI: "00-00-00", controllerID: 0, specVersion: "1.3", totalCapacityBytes: drive.sizeBytes, unallocatedCapacityBytes: 0, warningTempKelvin: 357, criticalTempKelvin: 373, namespaceCount: 1)
        return .init(reading: .nvme(.init(controller: controller, smart: sample.smart)), skippedAsleep: false, volumes: volumes)
    }
    private func volumes(_ drive: DriveInfo) throws -> [VolumeUsage] {
        let path = volumeRoot.appendingPathComponent(String(drive.id))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let actual = MountedFilesystemIdentity.capture(at: path) else { throw POSIXError(.EIO) }
        // Separate virtual targets share the fixture's real filesystem. UUIDs
        // are scripted; this provider never authorizes real measurement I/O.
        let identity = MountedFilesystemIdentity(filesystemID: actual.filesystemID, mountedFrom: actual.mountedFrom,
            mountedAt: actual.mountedAt, volumeUUID: String(format: "00000000-0000-0000-0000-%012llu", drive.id))
        return [.init(bsdName: drive.bsdName + "s1", name: "Private fixture volume \(drive.id)", mountPoint: path.path,
                      totalBytes: 128 << 30, availableBytes: 64 << 30, sharedCapacityKey: "fixture-pool-\(drive.id)",
                      mountIdentity: identity, writeIdentity: identity,
                      writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at: path))]
    }
    func workspaces(_ drive: DriveInfo, volume: VolumeUsage) async throws -> DiskWorkspaceScan {
        count("workspaces")
        return .init(leftovers: [], complete: true, diagnostic: nil, parentIdentity: volume.writeDirectoryIdentity)
    }
    func validate(_ drive: DriveInfo) async throws { count("validate") }
    func bridge(_ drive: DriveInfo) async throws -> USBBridgeInfo? { count("bridge"); return nil }
    func battery() async throws -> BatteryInfo? { count("battery"); return nil }
    func sensors() async throws -> [TemperatureSensor] {
        count("sensors")
        return try JSONDecoder().decode([TemperatureSensor].self, from: Data(#"[{"name":"CPU Fixture","celsius":44},{"name":"GPU Fixture","celsius":41},{"name":"NAND Fixture","celsius":37}]"#.utf8))
    }
    func memory() async throws -> MemoryStats? {
        count("memory")
        return try JSONDecoder().decode(MemoryStats.self, from: Data(#"{"totalBytes":17179869184,"freeBytes":4294967296,"activeBytes":4294967296,"inactiveBytes":2147483648,"wiredBytes":2147483648,"compressedBytes":1073741824,"swapUsedBytes":0,"swapTotalBytes":1073741824,"pressureLevel":1}"#.utf8))
    }
    func selfTestLog(_ drive: DriveInfo) async throws -> [ATASelfTestLogEntry] { count("selfTestLog"); return [] }
    private func ataReading(_ drive: DriveInfo) -> ATASMARTReading {
        let status: UInt8 = mode == "ataUnknown" ? 0xFF : mode == "ataKnown" ? 0xF5 : 0
        return .init(capturedAt: Date(), identify: .init(model: drive.model, serialNumber: drive.serialNumber ?? "", firmwareRevision: "F4", rotationRate: 1),
                     attributes: [], overallFailurePredicted: nil, selfTest: .init(rawByte: status), driveFamily: nil, driveWarning: nil, selfTestSupported: true)
    }
    func selfTestObservation(_ drive: DriveInfo, lease: DriveCommandLock.Lease, avoidWakingIdle: Bool) async throws -> SelfTestObservation {
        count("selfTestObservation")
        return .init(reading: ataReading(drive), log: try .init(capturedAt: Date(), mostRecentSlot: 0, entries: []))
    }
    func startSelfTest(_ drive: DriveInfo, extended: Bool) async throws { throw HardwareWorkerError.protocolViolation }
}
private actor WindowTrimCommands: SystemCommandRunning {
    var calls = 0
    func run(_ command: ProcessCommand) async throws -> CommandOutput {
        guard command.executable == "/usr/sbin/system_profiler", command.arguments == ["-json", "SPNVMeDataType", "SPSerialATADataType"] else { throw HardwareWorkerError.protocolViolation }
        calls += 1
        let json = #"{"SPNVMeDataType":[{"_items":[{"bsd_name":"disk101","spnvme_trim_support":"Yes"},{"bsd_name":"disk102","spnvme_trim_support":"No"}]}],"SPSerialATADataType":[{"_items":[{"bsd_name":"disk104","spsata_trim_support":"No"}]}]}"#
        return .init(stdout: Data(json.utf8), stderr: Data(), termination: .exited(0), processID: 0)
    }
}
private final class WindowHistoryOpenGate: @unchecked Sendable {
    private let lock = NSLock(), signal = DispatchSemaphore(value: 0)
    private var held: Bool
    private var didEnter = false
    init(held: Bool) { self.held = held }
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    func release() { lock.lock(); held = false; lock.unlock(); signal.signal() }
    func open(_ database: URL) throws -> HistoryStore {
        lock.lock(); didEnter = true; let wait = held; lock.unlock()
        if wait, signal.wait(timeout: .now() + 120) != .success { throw HistoryError.unavailable }
        return try HistoryStore(databaseURL: database)
    }
}
private struct WindowScanner: IOErrorScanning {
    func scan(withinMinutes: Int) async throws -> IOErrorScan { .init(events: [], diagnostics: .init()) }
}
private actor WindowMeasurements: MeasurementServing {
    let journalRoot: URL
    var mode = "success", mayFinish = false
    var calls: [String: Int] = [:]
    init(journalRoot: URL) { self.journalRoot = journalRoot }
    func set(_ mode: String) { self.mode = mode }
    func finish() { mayFinish = true }
    func prepareJournal(_ intent: MeasurementJobIntent) async throws -> MeasurementJobLease? {
        calls["prepare", default: 0] += 1
        return try MeasurementJournal(rootURL: journalRoot).prepare(intent)
    }
    func discardJournal(_ receipt: MeasurementHistoryReceipt) async throws {
        calls["discard", default: 0] += 1
        try await SystemMeasurementRecovery(rootURL: journalRoot).discard(receipt)
    }
    private func awaitRelease(job: MeasurementJobLease?, cancelled: @Sendable () -> Bool,
                              cleaning: @Sendable (Int) -> Void) async throws {
        let deadline = ContinuousClock().now + .seconds(120)
        while !mayFinish && !cancelled() && ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        if cancelled() {
            cleaning(2); try await Task.sleep(for: .milliseconds(300)); cleaning(0)
            if let job { try job.writeTerminal(.init(intent: job.intent, outcome: .cancelled)) }
            calls["cancelled", default: 0] += 1
            throw BenchmarkError.cancelled
        }
        guard mayFinish else { throw MeasurementWorkerError.remote("Fixture completion control was not released within 120 seconds") }
    }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        throw HardwareWorkerError.protocolViolation // Fixture requires its private journal-aware call.
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult { throw HardwareWorkerError.protocolViolation }
    func benchmark(drive: DriveInfo, volume: VolumeUsage, config: BenchmarkConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                   cancelled: @escaping @Sendable () -> Bool, progress: @escaping DiskBenchmarkEngine.ProgressHandler,
                   cleaning: @escaping @Sendable (Int) -> Void) async throws -> BenchmarkResult {
        calls["benchmark", default: 0] += 1; mayFinish = false
        let scenario = mode
        if scenario == "failure" {
            if let job { try job.writeTerminal(.init(intent: job.intent, outcome: .notStarted("Simulated fixture failure; no data I/O was executed"))) }
            throw MeasurementWorkerError.remote("Fixture measurement failure; no real data bytes were written")
        }
        progress(.init(phase: .sequentialWrite, fractionCompleted: 0.5, instantaneousBytesPerSecond: 800_000_000, averageBytesPerSecond: 800_000_000, processedBytes: config.fileSizeBytes / 2))
        try await awaitRelease(job: job, cancelled: cancelled, cleaning: cleaning)
        let phases: [BenchmarkPhase] = config.includeRandomPhases ? [.sequentialWrite, .sequentialRead, .randomWrite, .randomRead] : [.sequentialWrite, .sequentialRead]
        for phase in phases {
            for step in 1...4 {
                if cancelled() { try await awaitRelease(job: job, cancelled: cancelled, cleaning: cleaning) }
                let rate: Double = phase == .sequentialWrite ? 800_000_000 : phase == .sequentialRead ? 1_200_000_000 : 24_000_000
                progress(.init(phase: phase, fractionCompleted: Double(step) / 4, instantaneousBytesPerSecond: rate, averageBytesPerSecond: rate, processedBytes: config.fileSizeBytes * UInt64(step) / 4))
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        cleaning(0)
        let result = BenchmarkResult(capturedAt: Date(), volumeBSDName: volume.bsdName, volumeName: volume.name, mountPoint: volume.mountPoint,
                                     fileSizeBytes: config.fileSizeBytes, sequentialBlockBytes: config.sequentialBlockBytes, randomBlockBytes: config.randomBlockBytes,
                                     queueDepth: config.queueDepth, sequentialWriteBytesPerSec: scenario == "extreme" ? .greatestFiniteMagnitude : 800_000_000,
                                     sequentialReadBytesPerSec: scenario == "extreme" ? .greatestFiniteMagnitude : 1_200_000_000,
                                     randomWriteBytesPerSec: config.includeRandomPhases ? 24_000_000 : nil, randomReadBytesPerSec: config.includeRandomPhases ? 32_000_000 : nil)
        if let job { try job.writeTerminal(.init(intent: job.intent, outcome: .benchmark(result))); _ = try job.record() }
        calls["benchmarkCompleted", default: 0] += 1; return result
    }
    func capacity(drive: DriveInfo, volume: VolumeUsage, config: CapacityVerifyConfig, id: UUID, lease: DriveCommandLock.Lease, job: MeasurementJobLease?,
                  cancelled: @escaping @Sendable () -> Bool, progress: @escaping CapacityVerifier.ProgressHandler,
                  cleaning: @escaping @Sendable (Int) -> Void) async throws -> CapacityVerifyResult {
        calls["capacity", default: 0] += 1; mayFinish = false
        let scenario = mode, block = UInt64(config.blockBytes)
        let target = min(volume.availableBytes - config.reserveBytes, config.maxBytes ?? UInt64.max) / block * block
        progress(.init(phase: .filling, fractionCompleted: 0.5, bytesProcessed: target / 2, totalBytes: target, instantaneousBytesPerSecond: 100_000_000))
        try await awaitRelease(job: job, cancelled: cancelled, cleaning: cleaning)
        if scenario == "failure" {
            if let job { try job.writeTerminal(.init(intent: job.intent, outcome: .notStarted("Simulated fixture failure; no data I/O was executed"))) }
            throw MeasurementWorkerError.remote("Fixture capacity failure; no real data bytes were written")
        }
        progress(.init(phase: .verifying, fractionCompleted: 0.75, bytesProcessed: target * 3 / 4, totalBytes: target, instantaneousBytesPerSecond: 120_000_000))
        try await Task.sleep(for: .milliseconds(250)); cleaning(0)
        let incomplete = scenario == "inconclusive", corrupt = scenario == "corrupt"
        let written = incomplete ? target / block / 2 * block : target
        let result = CapacityVerifyResult(capturedAt: Date(), volumeName: volume.name, mountPoint: volume.mountPoint, bytesRequested: target,
                                          bytesWritten: written, bytesVerifiedOK: corrupt ? written - block : written,
                                          firstCorruptionOffset: corrupt ? 0 : nil, corruptedBlocks: corrupt ? 1 : 0,
                                          writeBytesPerSec: 100_000_000, readBytesPerSec: 120_000_000,
                                          verdict: incomplete ? .inconclusive : corrupt ? .dataCorrupted : .passedTestedRange,
                                          interruption: incomplete ? .readFailed : nil)
        if let job { try job.writeTerminal(.init(intent: job.intent, outcome: .capacity(result))); _ = try job.record() }
        calls["capacityCompleted", default: 0] += 1; return result
    }
}
@MainActor private final class WindowNotifications: NotificationDelivering {
    var accessCalls = 0, permissionCalls = 0, sends = 0
    func access() async -> NotificationAccess { accessCalls += 1; return .denied }
    func requestPermission() async throws -> Bool { permissionCalls += 1; return false }
    func send(_ alert: DriveAlert) async throws { sends += 1 }
}
@MainActor private final class WindowLogin: LoginItemManaging {
    var status: LoginItemStatus = .requiresApproval
    var requests: [Bool] = [], settingsOpens = 0
    func setEnabled(_ enabled: Bool) async throws { requests.append(enabled); status = enabled ? .requiresApproval : .notRegistered }
    func openSettings() { settingsOpens += 1 }
}

@MainActor @Observable private final class WindowHarness {
    static let shared = WindowHarness()
    let output: URL
    let exportDirectory: URL
    let hardware: WindowHardware, measurements: WindowMeasurements
    let notifications = WindowNotifications(), login = WindowLogin()
    let trimCommands = WindowTrimCommands()
    let historyGate = WindowHistoryOpenGate(held: CommandLine.arguments.contains("--hold-history"))
    let store: DriveStore, monitor: MonitoringController, benchmark: BenchmarkRunner, capacity: CapacityVerifyRunner
    let loginItems: LoginItemController, lifecycle: ApplicationLifecycle
    var actions: [String] = []
    var isBusy = false
    private var initialModeApplied = false
    init() {
        guard CommandLine.arguments.count >= 3 else { Darwin.exit(64) }
        output = URL(fileURLWithPath: CommandLine.arguments[1])
        exportDirectory = output.appendingPathComponent("share-temp")
        guard (try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])) != nil || FileManager.default.fileExists(atPath: exportDirectory.path) else { Darwin.exit(64) }
        hardware = WindowHardware(volumeRoot: output.appendingPathComponent("private-volumes"))
        measurements = WindowMeasurements(journalRoot: output.appendingPathComponent("private-journal"))
        let db = output.appendingPathComponent("history.sqlite")
        let gate = historyGate
        let store = DriveStore(history: HistoryAccess(factory: { try gate.open(db) }), ioScanner: WindowScanner(), hardware: hardware,
                               measurementRecovery: SystemMeasurementRecovery(rootURL: output.appendingPathComponent("private-journal")), trimCommands: trimCommands)
        self.store = store
        monitor = MonitoringController(store: store, delivery: notifications)
        benchmark = BenchmarkRunner(store: store, worker: measurements)
        capacity = CapacityVerifyRunner(store: store, worker: measurements)
        loginItems = LoginItemController(service: login)
        lifecycle = ApplicationLifecycle(store: store, monitor: monitor, benchmark: benchmark, capacity: capacity, loginItems: loginItems, launch: { throw CocoaError(.executableNotLoadable) })
        lifecycle.exitRequested = { [weak self] kind in self?.actions.append("fake-relaunch-request:\(kind)"); self?.save() }
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier!)
        SettingsKeys.registerDefaults()
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(false, forKey: SettingsKeys.monitoringEnabled)
        UserDefaults.standard.set(true, forKey: SettingsKeys.showMenuBar)
        UserDefaults.standard.set(MenuBarDisplay.temp.rawValue, forKey: SettingsKeys.menuBarDisplay)
    }
    func start() async {
        if !initialModeApplied {
            initialModeApplied = true
            if CommandLine.arguments.contains("--start-failed") { await hardware.set("failed") }
        }
        store.measurementRecovery.start(); await monitor.start(); await store.refresh(); save()
    }
    func repairProviderOnly() { actions.append("repair-provider-only"); Task { await hardware.set("fleet"); save() } }
    func changeFleet(_ mode: String) {
        guard !isBusy else { return }
        isBusy = true; actions.append(mode)
        Task { await hardware.set(mode); await store.refresh(wakingSleepingDrives: mode != "sleeping"); isBusy = false; save() }
    }
    func requestMissing() { actions.append("missing-id"); store.pendingSelection = 999; save() }
    func requestExternalIdentity() {
        actions.append("external-identity")
        store.pendingIdentitySelection = DriveIdentity.resolve(for: hardware.drives[1]).key
        save()
    }
    func setMeasurement(_ mode: String) {
        actions.append("measurement:" + mode)
        Task { await measurements.set(mode); save() }
    }
    func finishMeasurement() { actions.append("finish-fake-measurement"); Task { await measurements.finish(); save() } }
    func releaseHistory() { actions.append("release-history-open"); historyGate.release(); save() }
    private func colorComponents(_ color: Color, appearance: NSAppearance.Name) -> [CGFloat] {
        var result: NSColor?
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let result else { return [] }
        return [result.redComponent, result.greenComponent, result.blueComponent, result.alphaComponent]
    }
    func exportStatusColors() {
        actions.append("export-synthetic-status-colors")
        let drive = hardware.drives[0]
        let date = Date(timeIntervalSince1970: 1_791_500_000)
        let benchmark = BenchmarkResult(capturedAt: date, volumeBSDName: "fixture-color", volumeName: "Synthetic color fixture", mountPoint: output.path,
            fileSizeBytes: 1 << 20, sequentialBlockBytes: 1 << 20, randomBlockBytes: 4096, queueDepth: 1,
            sequentialWriteBytesPerSec: 800_000_000, sequentialReadBytesPerSec: 1_200_000_000,
            randomWriteBytesPerSec: 24_000_000, randomReadBytesPerSec: 32_000_000)
        for rating in HealthRating.allCases {
            let score: Int? = [.unknown: nil, .good: 100, .ok: 85, .warning: 65, .failing: 35, .failed: 10][rating] ?? nil
            let health = HealthReport(score: score, rating: rating, coverage: rating == .unknown ? .unavailable : .complete,
                lifetimeLeftPercent: nil, issues: [], capturedAt: date)
            _ = ShareCardRenderer.pngURL(for: BenchmarkShareCard(drive: drive, health: health, result: benchmark),
                name: "MDriveHealth-Palette-\(rating.rawValue)", directory: exportDirectory)
        }
        for verdict: CapacityVerifyResult.Verdict in [.passedTestedRange, .dataCorrupted, .inconclusive] {
            let result = CapacityVerifyResult(capturedAt: date, volumeName: "Synthetic color fixture", mountPoint: output.path,
                bytesRequested: 1 << 20, bytesWritten: verdict == .inconclusive ? 512 << 10 : 1 << 20,
                bytesVerifiedOK: verdict == .passedTestedRange ? 1 << 20 : 512 << 10,
                firstCorruptionOffset: verdict == .dataCorrupted ? 512 << 10 : nil,
                corruptedBlocks: verdict == .dataCorrupted ? 1 : 0,
                writeBytesPerSec: 800_000_000, readBytesPerSec: 1_200_000_000, verdict: verdict, interruption: nil)
            _ = ShareCardRenderer.pngURL(for: CapacityShareCard(drive: drive, result: result),
                name: "MDriveHealth-Palette-Capacity-\(verdict.rawValue)", directory: exportDirectory)
        }
        save()
    }
    func save() {
        Task { @MainActor in
            let proof: [String: Any] = ["actions": actions, "fleetIDs": store.snapshots.map(\.id), "visibleIDs": store.visibleSnapshots.map(\.id),
                "refreshing": store.isRefreshing, "refreshError": store.refreshError ?? "", "pendingSelection": store.pendingSelection.map(String.init) ?? "", "selectionError": store.selectionError ?? "",
                "fakeHardwareCalls": await hardware.calls, "fakeNotificationAccess": notifications.accessCalls, "fakePermissionCalls": notifications.permissionCalls, "fakeNotificationSends": notifications.sends,
                "fakeTrimMetadataCalls": await trimCommands.calls, "realSystemProfilerCalls": 0,
                "fakeMeasurementCalls": await measurements.calls, "fakeMeasurementMode": await measurements.mode,
                "benchmarkState": String(describing: benchmark.state), "benchmarkUnsaved": benchmark.unsavedResults.count, "benchmarkPersistenceError": benchmark.persistenceError ?? "", "benchmarkJournalWarnings": benchmark.journalCleanupIssues.count,
                "historyOpeningEntered": historyGate.entered, "historyState": String(describing: store.history.state),
                "historyIssues": Dictionary(uniqueKeysWithValues: store.history.issues.map { ($0.key, $0.value.message) }),
                "capacityState": String(describing: capacity.state), "capacityUnsaved": capacity.unsavedResults.count,
                "archivedMeasurementRecords": store.measurementRecovery.archivedRecords.count,
                "activeOperationKinds": store.operations.leases.values.map { $0.kind.rawValue },
                "exportDirectory": exportDirectory.path,
                "generatedShareImages": (try? FileManager.default.contentsOfDirectory(atPath: exportDirectory.path).filter { $0.hasPrefix("MDriveHealth-") && $0.hasSuffix(".png") }) ?? [],
                "loginRequests": login.requests, "fakeSettingsOpens": login.settingsOpens, "preferredLocalizations": Bundle.main.preferredLocalizations,
                "settings": [SettingsKeys.monitoringEnabled: UserDefaults.standard.bool(forKey: SettingsKeys.monitoringEnabled), SettingsKeys.showMenuBar: UserDefaults.standard.bool(forKey: SettingsKeys.showMenuBar), "appLanguage": UserDefaults.standard.string(forKey: "appLanguage") ?? "system"],
                "temperatureThreshold": UserDefaults.standard.integer(forKey: SettingsKeys.alertTempThreshold),
                "staleIDs": store.snapshots.filter(\.isStale).map(\.id),
                "menuBarRequested": CommandLine.arguments.contains("--menu-bar"),
                "statusColorComponents": Dictionary(uniqueKeysWithValues: HealthRating.allCases.map { rating in
                    (rating.rawValue, ["lightText": colorComponents(rating.color, appearance: .aqua),
                                      "darkText": colorComponents(rating.color, appearance: .darkAqua),
                                      "lightBadgeFill": colorComponents(rating.badgeFill, appearance: .aqua),
                                      "darkBadgeFill": colorComponents(rating.badgeFill, appearance: .darkAqua)])
                }),
                "menuBarStatus": ["unverified": store.menuBarStatus.isUnverified, "currentReadingCount": store.menuBarStatus.currentSnapshots.count,
                                  "accessibilityStatus": store.menuBarStatus.accessibilityStatus,
                                  "symbol": store.menuBarStatus.symbol, "temp": store.menuBarStatus.value(for: .temp) ?? "", "score": store.menuBarStatus.value(for: .score) ?? "",
                                  "refreshEnabled": store.menuBarStatus.refreshEnabled, "displayMode": UserDefaults.standard.string(forKey: SettingsKeys.menuBarDisplay) ?? ""] as [String: Any],
                "snapshotStates": Dictionary(uniqueKeysWithValues: store.snapshots.map { (String($0.id), ["stale": $0.isStale, "probing": $0.isProbing, "sleeping": $0.skippedWhileSleeping, "error": $0.lastError ?? ""] as [String: Any]) }),
                "reports": Dictionary(uniqueKeysWithValues: store.snapshots.map { (String($0.id), ReportGenerator.text(for: $0, ioErrors24h: nil)) }),
                "windowFrames": NSApp.windows.filter(\.isVisible).map { ["title": $0.title, "width": $0.frame.width, "height": $0.frame.height] as [String: Any] },
                "windowLayout": NSApp.windows.filter(\.isVisible).map { window in
                    ["title": window.title, "frameHeight": window.frame.height,
                     "contentHeight": window.contentView?.bounds.height ?? 0,
                     "contentFittingHeight": window.contentView?.fittingSize.height ?? 0,
                     "contentMinHeight": window.contentMinSize.height,
                     "contentMaxHeight": window.contentMaxSize.height] as [String: Any]
                },
                "realMeasurementDataBytesWritten": 0, "realHardwareMutations": 0, "realNotificationSDKCalls": 0, "realServiceManagementMutations": 0, "realRelaunches": 0, "productionAppLaunched": false]
            try? JSONSerialization.data(withJSONObject: proof, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("proof.json"), options: .atomic)
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("window-\(index).png"))
                }
            }
        }
    }
}

private struct FixtureStatusColors: View {
    let harness: WindowHarness
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Synthetic status color fixture").font(.headline)
            ForEach(HealthRating.allCases, id: \.self) { rating in
                HStack {
                    Text(rating.displayName).font(.caption).foregroundStyle(rating.color)
                    Spacer()
                    HealthBadge(rating: rating)
                }.padding(10).cardBackground()
            }
            Button("Generate private status export fixtures") { harness.exportStatusColors() }
            Text("Synthetic models only; no measurement I/O").font(.caption)
        }.padding(20).frame(width: 430)
    }
}

private struct FixtureActions: View {
    @Bindable var harness: WindowHarness
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fixture controls — fake boundaries").font(.headline)
            HStack { Button("Disconnect external") { harness.changeFleet("disconnected") }; Button("Reconnect") { harness.changeFleet("fleet") } }
            HStack { Button("Empty fleet") { harness.changeFleet("empty") }; Button("Discovery failure") { harness.changeFleet("failed") } }
            HStack { Button("Single drive") { harness.changeFleet("single") }; Button("Many drives") { harness.changeFleet("many") } }
            Button("Long discovery failure") { harness.changeFleet("longFailure") }
            HStack { Button("SMART probe failure") { harness.changeFleet("probeFailure") }; Button("Sleeping skipped") { harness.changeFleet("sleeping") } }
            Button("Repair provider without refresh") { harness.repairProviderOnly() }
            Button("Critical SMART with another read failure") { harness.changeFleet("criticalPartial") }
            HStack { Button("ATA progress unknown") { harness.changeFleet("ataUnknown") }; Button("ATA progress 50%") { harness.changeFleet("ataKnown") } }
            HStack { Button("Measurement success") { harness.setMeasurement("success") }; Button("Measurement failure") { harness.setMeasurement("failure") } }
            Button("Extreme finite benchmark result") { harness.setMeasurement("extreme") }
            HStack { Button("Capacity corrupt") { harness.setMeasurement("corrupt") }; Button("Capacity inconclusive") { harness.setMeasurement("inconclusive") } }
            Button("Finish fake measurement") { harness.finishMeasurement() }
            Button("Allow private history open") { harness.releaseHistory() }
            HStack { Button("Request missing ID") { harness.requestMissing() }; Button("Request external identity") { harness.requestExternalIdentity() } }
            Button("Capture proof") { harness.save() }
            Text("No real hardware/SDK mutation").font(.caption)
        }.padding().disabled(harness.isBusy)
    }
}
@MainActor private final class WindowFixtureDelegate: NSObject, NSApplicationDelegate {
    var panel: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: CommandLine.arguments[2] == "dark" ? .darkAqua : .aqua)
        let harness = WindowHarness.shared
        let panel = NSWindow(contentRect: NSRect(x: 20, y: 40, width: 500, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "MDriveHealth fixture controls"; panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: FixtureActions(harness: harness))
        panel.orderFront(nil); self.panel = panel
        DispatchQueue.global().asyncAfter(deadline: .now() + 900) { Darwin.exit(72) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { WindowHarness.shared.monitor.stop() }
}
@main private struct FullWindowNativeFixture: App {
    @NSApplicationDelegateAdaptor(WindowFixtureDelegate.self) var delegate
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @AppStorage(SettingsKeys.menuBarDisplay) private var menuBarDisplay = MenuBarDisplay.icon
    @Environment(\.openWindow) private var openWindow
    let harness = WindowHarness.shared
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView().environment(harness.store).environment(harness.monitor).environment(harness.benchmark).environment(harness.capacity).environment(harness.lifecycle).environment(harness.loginItems)
                .environment(\.shareImageDirectory, harness.exportDirectory)
                .frame(minWidth: 860, minHeight: 560)
                .task { await harness.start() }
        }.defaultSize(width: 860, height: 560).windowToolbarStyle(.unified)
        MenuBarExtra(isInserted: Binding(get: { CommandLine.arguments.contains("--menu-bar") && showMenuBar }, set: { showMenuBar = $0 })) {
            MenuBarView().environment(harness.store)
        } label: {
            MenuBarStatusLabel(display: menuBarDisplay).environment(harness.store)
        }.menuBarExtraStyle(.window)
        Window("Fixture menu bar content", id: "fixture-menu") {
            VStack(spacing: 0) {
                HStack { Text("Fixture status label").font(.caption); Spacer(); MenuBarStatusLabel(display: menuBarDisplay).environment(harness.store) }.padding(10)
                Divider()
                MenuBarView().environment(harness.store)
            }.frame(width: 300)
        }.windowResizability(.contentSize)
        Window("Fixture status colors", id: "fixture-colors") {
            FixtureStatusColors(harness: harness)
        }.windowResizability(.contentSize)
        Settings {
            SettingsView(history: harness.store.history, updater: SparkleUpdateController(prepareInstallation: { _ in })).environment(harness.monitor).environment(harness.lifecycle).environment(harness.loginItems)
        }
        .commands {
            CommandMenu("Fixture") {
                Button("Capture proof") { harness.save() }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Show fake controls") { delegate.panel?.makeKeyAndOrderFront(nil) }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show menu content") { openWindow(id: "fixture-menu") }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Show status colors") { openWindow(id: "fixture-colors") }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
    }
}
