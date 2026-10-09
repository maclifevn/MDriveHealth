/* TRIM metadata injection and operation ownership. GPL-3.0-or-later. */
import XCTest
@testable import MDriveHealthCore

private actor TrimFixtureCommands: SystemCommandRunning {
    private var outputs: [Result<CommandOutput, CommandError>]
    private var shouldHold: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var commands: [ProcessCommand] = []
    init(_ outputs: [Result<CommandOutput, CommandError>], hold: Bool = false) {
        self.outputs = outputs; shouldHold = hold
    }
    func release() { shouldHold = false; waiter?.resume(); waiter = nil }
    func run(_ command: ProcessCommand) async throws -> CommandOutput {
        commands.append(command)
        if shouldHold { await withCheckedContinuation { waiter = $0 } }
        guard !outputs.isEmpty else { throw HardwareWorkerError.protocolViolation }
        return try outputs.removeFirst().get()
    }
}

final class TrimMetadataTests: XCTestCase {
    @MainActor private var fixtures: [(DriveStore, URL, TrimFixtureCommands)] = []
    override func tearDown() async throws {
        try await closeFixtures()
        try await super.tearDown()
    }
    @MainActor private func closeFixtures() async throws {
        for (store, directory, runner) in fixtures {
            await runner.release(); store.beginShutdown()
            await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            try await store.history.shutdown()
            try FileManager.default.removeItem(at: directory)
        }
        fixtures.removeAll()
    }
    private var drive: DriveInfo {
        .init(registryEntryID: 842, bsdName: "disk842", model: "Private TRIM fixture", serialNumber: "TRIM-ONLY",
              firmwareRevision: "F", sizeBytes: 1_000_000, interconnect: "SATA", location: "External",
              isSolidState: true, smartInterface: .ata)
    }
    private func output(_ value: String?) -> CommandOutput {
        let item: [String: String] = value.map { ["bsd_name": drive.bsdName, "spsata_trim_support": $0] } ?? ["bsd_name": drive.bsdName]
        let data = try! JSONSerialization.data(withJSONObject: ["SPSerialATADataType": [["_items": [item]]]])
        return .init(stdout: data, stderr: Data(), termination: .exited(0), processID: 0)
    }
    @MainActor private func store(_ runner: TrimFixtureCommands) throws -> DriveStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("trim-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let store = DriveStore(history: HistoryAccess(factory: { throw HistoryError.unavailable }), hardware: FixtureHardware(drives: []),
                               measurementRecovery: SystemMeasurementRecovery(rootURL: directory.appendingPathComponent("journal")), trimCommands: runner)
        fixtures.append((store, directory, runner)); return store
    }

    @MainActor func testInjectedMetadataReadRetainsGlobalLeaseUntilItFinishesIncludingShutdown() async throws {
        let runner = TrimFixtureCommands([.success(output("Yes"))], hold: true)
        let store = try store(runner)
        let read = Task { try await store.readTrimSupport(drive) }
        let deadline = ContinuousClock().now + .seconds(5)
        while await runner.commands.isEmpty && ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.executable, "/usr/sbin/system_profiler")
        XCTAssertEqual(commands.first?.arguments, ["-json", "SPNVMeDataType", "SPSerialATADataType"])
        XCTAssertEqual(commands.first?.timeout, 15)
        XCTAssertEqual(store.operations.leases.count, 1)
        XCTAssertEqual(store.operations.leases.values.first?.kind, .trim)
        XCTAssertNil(store.operations.leases.values.first?.driveID)
        XCTAssertFalse(store.operations.canBegin(driveID: drive.id, kind: .benchmark))
        XCTAssertFalse(store.operations.canBegin(driveID: drive.id, kind: .capacity))
        store.beginShutdown()
        var drained = false
        let drain = Task { await store.operations.waitForIdle(); drained = true }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(drained)
        await runner.release()
        let value = try await read.value
        XCTAssertEqual(value, true)
        await drain.value
        XCTAssertTrue(drained)
        XCTAssertTrue(store.operations.leases.isEmpty)
    }

    @MainActor func testReportedSupportMissingSupportAndFailureStayDistinctAndReleaseLease() async throws {
        let runner = TrimFixtureCommands([.success(output("Yes")), .success(output("No")), .success(output(nil)), .failure(CommandError(.timedOut))])
        let store = try store(runner)
        let supported = try await store.readTrimSupport(drive)
        XCTAssertEqual(supported, true); XCTAssertTrue(store.operations.leases.isEmpty)
        let unsupported = try await store.readTrimSupport(drive)
        XCTAssertEqual(unsupported, false); XCTAssertTrue(store.operations.leases.isEmpty)
        let unreported = try await store.readTrimSupport(drive)
        XCTAssertNil(unreported); XCTAssertTrue(store.operations.leases.isEmpty)
        do { _ = try await store.readTrimSupport(drive); XCTFail("command failure must stay observable") }
        catch let error as CommandError { XCTAssertEqual(error.reason, .timedOut) }
        XCTAssertTrue(store.operations.leases.isEmpty)
        XCTAssertTrue(store.operations.canBegin(driveID: drive.id, kind: .capacity))
        let count = await runner.commands.count
        XCTAssertEqual(count, 4)
    }
}
