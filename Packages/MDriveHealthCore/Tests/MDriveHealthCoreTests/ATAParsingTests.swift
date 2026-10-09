/*
 * ATAParsingTests.swift
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class ATAParsingTests: XCTestCase {
    func testDriveDBLoadsAndMatchesSamsungSSD() throws {
        let db = DriveDB.shared
        XCTAssertGreaterThan(db.entries.count, 400, "drivedb.json should carry the full database")

        let match = db.match(model: "Samsung SSD 850 EVO 500GB", firmware: "EMT02B6Q", isSSD: true)
        XCTAssertEqual(match.family, "Samsung based SSDs")
        XCTAssertEqual(match.specs[177]?.name, "Wear_Leveling_Count")
        // Defaults still present for attributes the entry does not override.
        XCTAssertEqual(match.specs[5]?.name, "Reallocated_Sector_Ct")
    }

    func testDriveDBUnknownModelFallsBackToDefaults() {
        let match = DriveDB.shared.match(model: "TOTALLY UNKNOWN DRIVE 9000", firmware: nil, isSSD: false)
        XCTAssertNil(match.family)
        XCTAssertEqual(match.specs[9]?.name, "Power_On_Hours")
        XCTAssertEqual(match.specs[194]?.name, "Temperature_Celsius")
    }

    func testParseHealthySSDAttributes() {
        let (data, thresholds) = ATAFixtures.smartPages(ATAFixtures.healthySSD)
        let specs = DriveDB.shared.match(
            model: "Samsung SSD 850 EVO 500GB", firmware: nil, isSSD: true).specs
        let attrs = ATAParser.parseAttributes(data: data, thresholds: thresholds, specs: specs)

        XCTAssertEqual(attrs.count, 8)
        let realloc = attrs.first { $0.attributeID == 5 }!
        XCTAssertEqual(realloc.rawValue, 0)
        XCTAssertEqual(realloc.threshold, 10)
        XCTAssertTrue(realloc.isPrefail)
        XCTAssertFalse(realloc.failedNow)

        let poh = attrs.first { $0.attributeID == 9 }!
        XCTAssertEqual(poh.rawValue, 12_345)
        XCTAssertEqual(poh.name, "Power_On_Hours")
        XCTAssertFalse(poh.isPrefail)
    }

    func testParseDyingHDDDetectsTrippedAttribute() {
        let (data, thresholds) = ATAFixtures.smartPages(ATAFixtures.dyingHDD)
        let specs = DriveDB.shared.defaultSpecs(isSSD: false)
        let attrs = ATAParser.parseAttributes(data: data, thresholds: thresholds, specs: specs)

        let realloc = attrs.first { $0.attributeID == 5 }!
        XCTAssertEqual(realloc.rawValue, 1_824)
        XCTAssertTrue(realloc.failedNow, "current 3 <= threshold 36 must trip")

        let temp = attrs.first { $0.attributeID == 194 }!
        XCTAssertEqual(temp.rawValue, 45)
        XCTAssertEqual(temp.rawDisplay, "45 (Min/Max 21/45)")

        let pending = attrs.first { $0.attributeID == 197 }!
        XCTAssertEqual(pending.rawValue, 216)
    }

    func testParseIdentify() throws {
        let block = ATAFixtures.identify(
            model: "ST2000LM007-1R8174", serial: "WCC4N123", firmware: "SBK2", rotationRate: 5400)
        let info = try XCTUnwrap(ATAParser.parseIdentify(block))
        XCTAssertEqual(info.model, "ST2000LM007-1R8174")
        XCTAssertEqual(info.serialNumber, "WCC4N123")
        XCTAssertEqual(info.firmwareRevision, "SBK2")
        XCTAssertEqual(info.rpm, 5400)
        XCTAssertFalse(info.isSolidState)
    }

    func testSelfTestStatusParsing() throws {
        let (running, _) = ATAFixtures.smartPages([], selfTestByte: 0xF4)
        let status = try XCTUnwrap(ATAParser.parseSelfTestStatus(data: running))
        XCTAssertTrue(status.inProgress)
        XCTAssertEqual(status.percentRemaining, 40)

        let (idle, _) = ATAFixtures.smartPages([], selfTestByte: 0x00)
        XCTAssertFalse(ATAParser.parseSelfTestStatus(data: idle)?.inProgress == true)
    }

    func testReservedSelfTestProgressCannotBecomeAnOutOfRangePercentage() throws {
        for nibble in UInt8(0)...9 {
            let (data, _) = ATAFixtures.smartPages([], selfTestByte: 0xF0 | nibble)
            let status = try XCTUnwrap(ATAParser.parseSelfTestStatus(data: data))
            XCTAssertTrue(status.inProgress)
            XCTAssertEqual(status.percentRemaining, Int(nibble) * 10)
        }
        for nibble in UInt8(10)...15 {
            let (data, _) = ATAFixtures.smartPages([], selfTestByte: 0xF0 | nibble)
            XCTAssertNil(ATAParser.parseSelfTestStatus(data: data), "the parser continues rejecting reserved raw SMART status")
            let status = ATASelfTestStatus(rawByte: 0xF0 | nibble)
            XCTAssertTrue(status.inProgress)
            XCTAssertNil(status.percentRemaining)
        }
        XCTAssertNil(ATASelfTestStatus(rawByte: 0).percentRemaining)
    }

    func testRawDecoderFormats() {
        let bytes: (UInt64) -> [UInt8] = { v in (0..<6).map { UInt8((v >> (8 * $0)) & 0xFF) } }

        XCTAssertEqual(ATARawDecoder.decode(raw: bytes(7200), format: "seconds").display, "2h+00m+00s")
        XCTAssertEqual(ATARawDecoder.decode(raw: bytes(7200), format: "seconds").value, 2)
        XCTAssertEqual(ATARawDecoder.decode(raw: bytes(150), format: "minutes").display, "2h+30m")
        XCTAssertEqual(ATARawDecoder.decode(raw: bytes(345), format: "temp10x").display, "34.5")
        XCTAssertEqual(ATARawDecoder.decode(raw: bytes(0xABCD), format: "hex48").display, "0x00000000abcd")
        // raw24/raw32: high 16 bits = primary counter
        let split = ATARawDecoder.decode(raw: [0x01, 0x00, 0x00, 0x00, 0x05, 0x00], format: "raw24/raw32", reserved: 0)
        XCTAssertEqual(split.value, 5)
        XCTAssertEqual(split.display, "5/1")
    }

    func testATABytesWrittenHonorsAttributeUnits() {
        func attribute(name: String, raw: UInt64) -> ATAAttribute {
            ATAAttribute(
                attributeID: 241, name: name, flags: 0, current: 100, worst: 100,
                threshold: nil, rawBytes: [], rawValue: raw, rawDisplay: "\(raw)")
        }
        func reading(name: String, raw: UInt64) -> DriveReading {
            .ata(ATASMARTReading(
                capturedAt: Date(), identify: nil,
                attributes: [attribute(name: name, raw: raw)],
                overallFailurePredicted: nil, selfTest: nil,
                driveFamily: nil, driveWarning: nil))
        }

        XCTAssertEqual(reading(name: "Total_LBAs_Written", raw: 2).bytesWritten, 1_024)
        XCTAssertEqual(reading(name: "Host_Writes_GiB", raw: 3).bytesWritten, 3_221_225_472)
        XCTAssertNil(reading(name: "Vendor_Specific_Counter", raw: 99).bytesWritten)
    }
}
