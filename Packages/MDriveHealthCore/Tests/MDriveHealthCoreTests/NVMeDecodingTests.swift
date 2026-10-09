/*
 * NVMeDecodingTests.swift
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore
import CSMART

final class NVMeDecodingTests: XCTestCase {
    func testStructSizesMatchSpec() {
        XCTAssertEqual(MemoryLayout<MDNVMeSMARTLog>.size, 512)
        XCTAssertEqual(MemoryLayout<MDNVMeIdentifyController>.size, 4096)
    }

    func testSMARTLogDecoding() {
        var log = MDNVMeSMARTLog()
        log.criticalWarning = 0b0000_0101 // spare below threshold + reliability degraded
        log.temperature = (0x38, 0x01)    // 0x0138 = 312 K = 39°C
        log.availableSpare = 97
        log.availableSpareThreshold = 10
        log.percentageUsed = 12
        withUnsafeMutableBytes(of: &log.dataUnitsRead) { $0.storeBytes(of: UInt64(123_456).littleEndian, as: UInt64.self) }
        withUnsafeMutableBytes(of: &log.powerOnHours) { $0.storeBytes(of: UInt64(4_321).littleEndian, as: UInt64.self) }

        let snapshot = NVMeSMARTProvider.decode(log: log)
        XCTAssertTrue(snapshot.criticalWarning.contains(.spareBelowThreshold))
        XCTAssertTrue(snapshot.criticalWarning.contains(.reliabilityDegraded))
        XCTAssertFalse(snapshot.criticalWarning.contains(.mediaReadOnly))
        XCTAssertEqual(snapshot.temperatureKelvin, 312)
        XCTAssertEqual(snapshot.temperatureCelsius, 39)
        XCTAssertEqual(snapshot.availableSpare, 97)
        XCTAssertEqual(snapshot.percentageUsed, 12)
        XCTAssertEqual(snapshot.dataUnitsRead, 123_456)
        XCTAssertEqual(snapshot.bytesRead, 123_456 * 512_000)
        XCTAssertEqual(snapshot.powerOnHours, 4_321)
    }

    func testIdentifyDecoding() {
        var identify = MDNVMeIdentifyController()
        // "APPLE SSD TEST" space-padded into the 40-byte model field.
        let model = Array("APPLE SSD TEST".utf8)
        withUnsafeMutableBytes(of: &identify.modelNumber) { raw in
            for (offset, byte) in model.enumerated() { raw[offset] = byte }
            for offset in model.count..<40 { raw[offset] = UInt8(ascii: " ") }
        }
        identify.ver = (1 << 16) | (4 << 8)
        identify.wctemp = 357

        let info = NVMeSMARTProvider.decode(identify: identify)
        XCTAssertEqual(info.model, "APPLE SSD TEST")
        XCTAssertEqual(info.specVersion, "1.4.0")
        XCTAssertEqual(info.warningTempKelvin, 357)
    }
}
