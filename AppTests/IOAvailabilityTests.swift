/* Actual model/service tests with deterministic providers; no device I/O.
 * MDriveHealth, GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private struct ScanFailure: LocalizedError, Sendable { var errorDescription: String? { "fixture scan unavailable" } }
private actor ScriptedScanner: IOErrorScanning {
    let steps: [Result<IOErrorScan, ScanFailure>]
    let delay: Duration
    private(set) var calls = 0
    init(_ steps: [Result<IOErrorScan, ScanFailure>], delay: Duration = .zero) { self.steps = steps; self.delay = delay }
    func scan(withinMinutes: Int) async throws -> IOErrorScan {
        let index = calls; calls += 1
        if delay != .zero { try await Task.sleep(for: delay) }
        return try steps[min(index, steps.count - 1)].get()
    }
}
private actor ScriptedCommands: SystemCommandRunning {
    let outputs: [Result<CommandOutput, CommandError>]
    private(set) var commands: [ProcessCommand] = []
    init(_ outputs: [Result<CommandOutput, CommandError>]) { self.outputs = outputs }
    func run(_ command: ProcessCommand) async throws -> CommandOutput {
        let index = commands.count; commands.append(command)
        return try outputs[min(index, outputs.count - 1)].get()
    }
}
final class IOAvailabilityTests: XCTestCase {
    @MainActor func testScanFailureKeepsUnknownStatusAndRetryClearsIt() async {
        let empty = IOErrorScan(events: [], diagnostics: .init())
        let scanner = ScriptedScanner([.failure(ScanFailure()), .success(empty)])
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), ioScanner: scanner)
        await store.refreshIOErrors(for: ["disk1"], force: true)
        XCTAssertNotNil(store.ioScanIssue); XCTAssertNil(store.lastSuccessfulIOScan)
        XCTAssertFalse(store.isIOScanning)
        await store.refreshIOErrors(for: ["disk1"], force: true)
        XCTAssertNil(store.ioScanIssue); XCTAssertNotNil(store.lastSuccessfulIOScan)
        XCTAssertEqual(store.ioErrorCounts["disk1"], 0)
    }
    @MainActor func testMalformedRecordsKeepPartialStatusAndKnownErrors() async {
        var diagnostic = IOErrorScanDiagnostics(); diagnostic.invalidTimestamps = 1
        let event = IOErrorEvent(date: Date().addingTimeInterval(-60), message: "I/O error disk1")
        let partial = IOErrorScan(events: [event], diagnostics: diagnostic)
        let scanner = ScriptedScanner([.success(partial), .failure(ScanFailure())])
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), ioScanner: scanner)
        await store.refreshIOErrors(for: ["disk1"], force: true)
        XCTAssertEqual(store.ioErrorCounts["disk1"], 1); XCTAssertNotNil(store.ioScanIssue)
        XCTAssertNil(store.lastSuccessfulIOScan, "partial data cannot claim a successful scan")
        await store.refreshIOErrors(for: ["disk1"], force: true)
        XCTAssertEqual(store.ioErrorCounts["disk1"], 1); XCTAssertNotNil(store.ioScanIssue)
    }
    @MainActor func testScanIsAsyncCoalescedAndBlockedByMeasurementGuard() async throws {
        let scanner = ScriptedScanner([.success(.init(events: [], diagnostics: .init()))], delay: .milliseconds(80))
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), ioScanner: scanner)
        let lease = try store.operations.begin(driveID: 1, kind: .benchmark)
        await store.refreshIOErrors(for: [], force: true)
        let before = await scanner.calls; XCTAssertEqual(before, 0)
        store.operations.end(lease)
        let task = Task { await store.refreshIOErrors(for: [], force: true) }
        while !store.isIOScanning { await Task.yield() }
        await store.refreshIOErrors(for: [], force: true)
        XCTAssertTrue(store.isIOScanning, "second request returned while the first remains suspended, leaving MainActor responsive")
        await task.value
        let after = await scanner.calls; XCTAssertEqual(after, 1)
    }
    private func output(_ stdout: String = "", stderr: String = "", code: Int32 = 0) -> CommandOutput {
        .init(stdout: Data(stdout.utf8), stderr: Data(stderr.utf8), termination: .exited(code), processID: 1)
    }
    private var drive: DriveInfo {
        .init(registryEntryID: 1, bsdName: "disk1", model: "Test", serialNumber: "SN-A", firmwareRevision: "F",
              sizeBytes: 1000, interconnect: "USB", location: "External", isSolidState: true, smartInterface: .unsupported)
    }
    private var volumes: [VolumeUsage] {
        [.init(bsdName: "disk1s1", name: "Fixture", mountPoint: "/Volumes/Fixture", totalBytes: 1000, availableBytes: 900, sharedCapacityKey: "disk1s1")]
    }
    func testTRIMUnreportedValueOrCommandFailureStaysUnknown() async {
        let unknown = "{\"SPNVMeDataType\":[{\"_items\":[{\"bsd_name\":\"disk1\",\"spnvme_trim_support\":\"Unavailable\"}]}]}"
        let runner = ScriptedCommands([.success(output(unknown)), .failure(CommandError(.timedOut))])
        let a = await TrimStatusReader.trimSupport(bsdName: "disk1", runner: runner)
        let b = await TrimStatusReader.trimSupport(bsdName: "disk1", runner: runner)
        XCTAssertNil(a); XCTAssertNil(b)
    }
    func testEjectTimeoutIsFailureAndDoesNotLaunchMoreCommands() async {
        let runner = ScriptedCommands([.failure(CommandError(.timedOut))])
        guard case .failed(let message) = await EjectService.eject(drive: drive, volumes: volumes, force: false, runner: runner) else { return XCTFail("timeout must not be reported as eject success") }
        XCTAssertTrue(message.contains("deadline"))
        let commands = await runner.commands; XCTAssertEqual(commands.count, 1)
    }
    func testBlockerReadFailureIsNotNoBlockersAndRealNamesAreReturned() async {
        let unavailable = ScriptedCommands([.success(output("refused", code: 1)), .success(output(stderr: "permission denied", code: 1))])
        guard case .failed(let message) = await EjectService.eject(drive: drive, volumes: volumes, force: false, runner: unavailable) else { return XCTFail("unknown blockers must remain failed") }
        XCTAssertTrue(message.contains("permission denied"))
        let partial = ScriptedCommands([.success(output("refused", code: 1)), .success(output("cFinder\n", stderr: "permission denied"))])
        guard case .failed(let partialMessage) = await EjectService.eject(drive: drive, volumes: volumes, force: false, runner: partial) else { return XCTFail("stderr must disclose an incomplete blocker listing even with exit zero") }
        XCTAssertTrue(partialMessage.contains("permission denied"))
        let names = ScriptedCommands([.success(output("refused", code: 1)), .success(output("cFinder\ncPreview\ncFinder\n"))])
        guard case .blocked(let blockers) = await EjectService.eject(drive: drive, volumes: volumes, force: false, runner: names) else { return XCTFail("expected blocker names") }
        XCTAssertEqual(blockers, ["Finder", "Preview"])
    }
    func testForceRequestUsesOnlyBoundedDiskutilCommand() async {
        let runner = ScriptedCommands([.success(output())])
        guard case .ejected = await EjectService.eject(drive: drive, volumes: volumes, force: true, runner: runner) else { return XCTFail("expected success") }
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands[0].arguments, ["unmountDisk", "force", "/dev/disk1"])
        XCTAssertLessThanOrEqual(commands[0].stdoutLimit, 1_048_576)
    }
}
