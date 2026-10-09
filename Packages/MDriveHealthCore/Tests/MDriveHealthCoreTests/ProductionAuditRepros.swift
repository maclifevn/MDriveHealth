// Production audit, 2026-10-08. These tests describe required safe behavior.
// Included in the regular SwiftPM suite and CI. GPL-3.0-or-later.
// All writes are tiny fixtures in a unique temporary directory.
import XCTest
import Darwin
@testable import MDriveHealthCore

final class ProductionAuditRepros: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdrivehealth-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func volume(at url: URL) -> VolumeUsage {
        VolumeUsage(bsdName: "disk999s1", name: "Audit fixture", mountPoint: url.path,
                    totalBytes: 1 << 40, availableBytes: 1 << 40,
                    sharedCapacityKey: "audit")
    }

    private var tinyCapacity: CapacityVerifyConfig {
        CapacityVerifyConfig(reserveBytes: 1 << 20, fileSizeBytes: 8192,
                             blockBytes: 4096, maxBytes: 8192)
    }

    private func attribute(_ id: UInt8, name: String, raw: UInt64,
                           current: UInt8 = 100) -> ATAAttribute {
        ATAAttribute(attributeID: id, name: name, flags: 0, current: current,
                     worst: current, threshold: nil, rawBytes: [], rawValue: raw,
                     rawDisplay: String(raw))
    }

    private func ata(_ attributes: [ATAAttribute], ssd: Bool = true) -> ATASMARTReading {
        let identify = ATAIdentifyInfo(model: "Audit SSD", serialNumber: "AUDIT",
                                       firmwareRevision: "1", rotationRate: ssd ? 1 : 5400)
        return ATASMARTReading(capturedAt: Date(), identify: identify, attributes: attributes,
                               overallFailurePredicted: false, selfTest: nil,
                               driveFamily: nil, driveWarning: nil)
    }

    func testCapacityCleanupPreservesUnownedFiles() throws {
        let v = volume(at: root)
        let directory = CapacityVerifier.testDirectoryURL(for: v)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("user-data.txt")
        try Data("must survive".utf8).write(to: sentinel)
        XCTAssertThrowsError(try CapacityVerifier().run(
            volume: v, config: tinyCapacity, isCancelled: { true }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path),
                      "F01: cleanup deleted a pre-existing file without checking ownership")
    }

    func testBenchmarkCleanupPreservesUnownedFile() throws {
        let file = root.appendingPathComponent(BenchmarkLocation.testFileName)
        try Data("must survive".utf8).write(to: file)
        let config = BenchmarkConfig(fileSizeBytes: 8192, sequentialBlockBytes: 4096,
                                     includeRandomPhases: false)
        XCTAssertThrowsError(try DiskBenchmarkEngine().run(
            testFileURL: file, volume: volume(at: root), config: config,
            isCancelled: { true }, progress: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "F01: benchmark unlinked a pre-existing file before O_EXCL")
    }

    func testCapacityRejectsMissingMountInsteadOfCreatingIt() throws {
        let missing = root.appendingPathComponent("unplugged-volume")
        var acknowledged = tinyCapacity
        acknowledged.dataRiskAcknowledged = true
        acknowledged.sharedCapacityRiskAcknowledged = true
        XCTAssertThrowsError(try CapacityVerifier().run(
            volume: volume(at: missing), config: acknowledged),
            "F02: stale mount path was recreated and accepted on the parent filesystem")
    }

    func testCappedCapacityReportsOnlyTestedRange() throws {
        let result = try CapacityVerifier().run(in: root, volume: volume(at: root), config: tinyCapacity)
        XCTAssertEqual(result.bytesWritten, 8192)
        XCTAssertEqual(result.verdict, .passedTestedRange)
        XCTAssertEqual(result.bytesRequested, 8192)
    }

    func testFactoryBadBlockCounterDoesNotMeanEndToEndFailure() {
        let reading = ata([attribute(184, name: "Factory_Bad_Block_Count", raw: 100)])
        XCTAssertEqual(HealthEvaluator.evaluate(ata: reading).rating, .unknown,
                       "F05: drivedb gives attribute 184 a factory bad block meaning on OCZ SSDs")
    }

    func testHostReadCounterDoesNotMeanUncorrectableSectors() {
        let reading = ata([attribute(198, name: "Host_Reads_GiB", raw: 100)])
        XCTAssertNil(DriveReading.ata(reading).defectCount,
                       "F05: host reads were counted as media defects")
        XCTAssertEqual(HealthEvaluator.evaluate(ata: reading).rating, .unknown,
                       "F05: normal host reads were classified as a failing drive")
    }

    func testNANDWritesDoNotProvideLifetimeRemaining() {
        let reading = ata([attribute(233, name: "NAND_GiB_Written", raw: 100)])
        XCTAssertNil(HealthEvaluator.evaluate(ata: reading).lifetimeLeftPercent,
                     "F06: a NAND write counter was interpreted as lifetime remaining")
    }

    func testControllerTemperatureDoesNotProvideLifetimeRemaining() {
        let reading = ata([attribute(231, name: "Controller_Temperature", raw: 35)])
        XCTAssertNil(HealthEvaluator.evaluate(ata: reading).lifetimeLeftPercent,
                     "F06: a temperature attribute was interpreted as lifetime remaining")
    }

    func testATAParserHonorsExplicitByteOrder() throws {
        var page = [UInt8](repeating: 0, count: 512)
        page[2] = 198
        for (i, byte) in [UInt8(1), 2, 3, 4, 5, 6].enumerated() { page[7 + i] = byte }
        page[0] = 0x10
        page[511] = 0 &- page.reduce(UInt8(0), &+)
        let specs: [UInt8: ATAAttributeSpec] = [
            198: ATAAttributeSpec(format: "raw48", byteorder: "012345", name: "Audit_counter")
        ]
        let result = try XCTUnwrap(ATAParser.parseAttributes(
            data: page, thresholds: nil, specs: specs).first)
        XCTAssertEqual(result.rawValue, 0x010203040506,
                       "F07: ATAAttributeSpec.byteorder was ignored")
    }

    func testRaw64IncludesCurrentAndWorstBytes() throws {
        var page = [UInt8](repeating: 0, count: 512)
        page[2] = 9
        page[5] = 0x12 // current
        page[6] = 0x34 // worst
        page[7] = 1    // raw[0]
        page[0] = 0x10
        page[511] = 0 &- page.reduce(UInt8(0), &+)
        let specs: [UInt8: ATAAttributeSpec] = [
            9: ATAAttributeSpec(format: "raw64", name: "Power_On_Hours")
        ]
        let result = try XCTUnwrap(ATAParser.parseAttributes(
            data: page, thresholds: nil, specs: specs).first)
        XCTAssertEqual(result.rawValue, 0x013412,
                       "F07: smartmontools raw64 uses byte order 543210wv, not only six raw bytes")
    }

    func testEmptySMARTDoesNotMeanPerfectHealth() {
        let reading = ATASMARTReading(capturedAt: Date(), identify: nil, attributes: [],
                                      overallFailurePredicted: nil, selfTest: nil,
                                      driveFamily: nil, driveWarning: nil)
        let report = HealthEvaluator.evaluate(ata: reading)
        XCTAssertFalse(report.rating == .good && report.score == 100,
                       "F08: no usable SMART data still produced Good 100/100")
    }

    func testDifferentUnidentifiedDrivesDoNotShareHistory() {
        func drive(_ id: UInt64, bsdName: String) -> DriveInfo {
            DriveInfo(registryEntryID: id, bsdName: bsdName, model: "Generic SSD",
                      serialNumber: nil, firmwareRevision: nil, sizeBytes: 1 << 40,
                      interconnect: "USB", location: "External", isSolidState: true,
                      smartInterface: .unsupported)
        }
        XCTAssertNotEqual(HistoryStore.driveKey(for: drive(1, bsdName: "disk3")),
                          HistoryStore.driveKey(for: drive(2, bsdName: "disk5")),
                          "F13: model + capacity collides for distinct unidentifiable devices")
    }

    func testNonFiniteRandomDurationIsRejected() {
        let config = BenchmarkConfig(randomPhaseSeconds: .infinity)
        XCTAssertThrowsError(try config.validate(),
                             "F18: infinite random benchmark duration is accepted")
    }

    func testMemoryPollingDoesNotLeakHostPortReferences() throws {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var before: mach_port_urefs_t = 0
        var after: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host,
                                         mach_port_right_t(MACH_PORT_RIGHT_SEND), &before), KERN_SUCCESS)
        for _ in 0..<100 { _ = MemoryReader.read() }
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host,
                                         mach_port_right_t(MACH_PORT_RIGHT_SEND), &after), KERN_SUCCESS)
        XCTAssertEqual(after, before, "F19: periodic RAM polling leaked host Mach send-right references")
    }
}
