/*
 * Vendor collision, payload validity and smartmontools parity regressions.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */
import XCTest
import CSMART
@testable import MDriveHealthCore

final class SMARTSafetyTests: XCTestCase {
    private func reading(model: String = "Unknown SSD", ssd: Bool = true,
                         attributes: [ATAAttribute], status: Bool? = false,
                         family: String? = nil) -> ATASMARTReading {
        .init(capturedAt: Date(), identify: .init(model: model, serialNumber: "S", firmwareRevision: "F",
                                                rotationRate: ssd ? 1 : 7200),
              attributes: attributes, overallFailurePredicted: status, selfTest: nil,
              driveFamily: family, driveWarning: nil)
    }
    private func attribute(_ id: UInt8, _ name: String, raw: UInt64 = 100,
                           current: UInt8 = 100, source: ATANameSource = .explicit) -> ATAAttribute {
        .init(attributeID: id, name: name, flags: 0, current: current, worst: current,
              threshold: 0, rawBytes: [], rawValue: raw, rawDisplay: String(raw), nameSource: source)
    }
    private func vendor(_ model: String, id: UInt8, current: UInt8, raw: UInt64) -> ATASMARTReading {
        let match = DriveDB.shared.match(model: model, firmware: nil, isSSD: true)
        let pages = ATAFixtures.smartPages([.init(id, current: current, worst: current, raw: raw, threshold: 0)])
        return reading(model: model, attributes: ATAParser.parseAttributes(data: pages.data, thresholds: pages.thresholds, specs: match.specs), family: match.family)
    }

    func testCollidingIDsDoNotBecomeMediaFailures() {
        for (id, name) in [(UInt8(184), "Factory_Bad_Block_Count"), (198, "Host_Reads_GiB"),
                           (5, "Retired_Block_Count"), (197, "Total_Pending_Sectors")] {
            let sample = reading(attributes: [attribute(id, name)])
            XCTAssertNil(DriveReading.ata(sample).defectCount, name)
            XCTAssertNil(DriveReading.ata(sample).pendingSectors, name)
            XCTAssertFalse(HealthEvaluator.evaluate(ata: sample).issues.contains { $0.severity >= .warning }, name)
            XCTAssertNil(HealthEvaluator.evaluate(ata: sample).score, name)
        }
    }
    func testKnownMediaCountersAreSharedByScoreAndHistory() {
        let sample = reading(ssd: false, attributes: [attribute(5, "Reallocated_Sector_Ct", raw: 99),
                                                     attribute(197, "Current_Pending_Sector", raw: 5)])
        XCTAssertEqual(DriveReading.ata(sample).defectCount, 99)
        XCTAssertEqual(DriveReading.ata(sample).dangerousDefectTotal, 104)
        let report = HealthEvaluator.evaluate(ata: sample)
        XCTAssertNil(report.score)
        XCTAssertEqual(report.coverage, .partial)
        XCTAssertGreaterThanOrEqual(report.rating, .failing)
        XCTAssertTrue(report.issues.contains { $0.id == "ata.197.raw" })
    }
    func testUnknownSSDDefaultsDoNotCertifyCounters() {
        let sample = reading(attributes: [attribute(5, "Reallocated_Sector_Ct", raw: 9, source: .generic)])
        XCTAssertNil(DriveReading.ata(sample).defectCount)
        XCTAssertEqual(HealthEvaluator.evaluate(ata: sample).rating, .unknown)
    }
    func testUnmatchedHDDStillReportsKnownProblemsWithoutScore() {
        let sample = reading(ssd: false, attributes: [attribute(5, "Reallocated_Sector_Ct", raw: 90, source: .generic)])
        XCTAssertEqual(DriveReading.ata(sample).defectCount, 90)
        XCTAssertEqual(HealthEvaluator.evaluate(ata: sample).rating, .failing)
        XCTAssertNil(HealthEvaluator.evaluate(ata: sample).score)
    }
    func testNoAttributesOrOverallStatusIsUnavailable() {
        let sample = ATASMARTReading(capturedAt: Date(), identify: nil, attributes: [],
                                    overallFailurePredicted: nil, selfTest: nil, driveFamily: nil, driveWarning: nil)
        let report = HealthEvaluator.evaluate(ata: sample)
        XCTAssertEqual(report.rating, .unknown)
        XCTAssertEqual(report.coverage, .unavailable)
        XCTAssertNil(report.score)
        XCTAssertNil(DriveReading.ata(sample).dangerousDefectTotal)
    }
    func testStatusFailureSurvivesMissingAttributes() {
        let report = HealthEvaluator.evaluate(ata: reading(attributes: [], status: true))
        XCTAssertEqual(report.coverage, .partial)
        XCTAssertEqual(report.rating, .failing)
        XCTAssertNil(report.score)
    }
    func testUnsupportedWearNamesDoNotInventPercent() {
        for (id, name) in [(UInt8(231), "Controller_Temperature"), (233, "NAND_GiB_Written"),
                           (169, "Bad_Block_Count"), (202, "Exception_Mode_Status"),
                           (177, "Wear_Range_Delta"), (173, "Erase_Count")] {
            let report = HealthEvaluator.evaluate(ata: reading(attributes: [attribute(id, name)], family: "Samsung based SSDs"))
            XCTAssertNil(report.lifetimeLeftPercent, name)
        }
    }
    func testSamsungWearUsesRemainingNormalizedNotEraseCount() {
        let sample = vendor("Samsung SSD 850 EVO 500GB", id: 177, current: 93, raw: 456)
        XCTAssertEqual(HealthEvaluator.evaluate(ata: sample).lifetimeLeftPercent, 93)
        XCTAssertEqual(HealthEvaluator.evaluate(ata: sample).score, 100)
    }
    func testIntelWearUsesNormalizedRemaining() {
        let sample = vendor("INTEL SSDSCKKW512G8", id: 233, current: 81, raw: 0)
        XCTAssertEqual(sample.driveFamily, "Intel 545s Series SSDs")
        XCTAssertEqual(HealthEvaluator.evaluate(ata: sample).lifetimeLeftPercent, 81)
    }
    func testMicronWearUsesNormalizedRemainingDespiteRawUsed() {
        let sample = vendor("CT500MX500SSD1", id: 202, current: 88, raw: 12)
        XCTAssertEqual(sample.driveFamily, "Crucial/Micron Client SSDs")
        XCTAssertEqual(HealthEvaluator.evaluate(ata: sample).lifetimeLeftPercent, 88)
    }
    func testOutOfRangeNormalizedWearIsUnknown() {
        let sample = vendor("Samsung SSD 850 EVO 500GB", id: 177, current: 254, raw: 5)
        XCTAssertNil(HealthEvaluator.evaluate(ata: sample).lifetimeLeftPercent)
        XCTAssertNil(HealthEvaluator.evaluate(ata: sample).score)
    }
    func testDefaultsAreMediumAware() {
        let ssd = DriveDB.shared.match(model: "Unknown", firmware: nil, isSSD: true).specs
        XCTAssertNil(ssd[231]); XCTAssertNil(ssd[10]); XCTAssertNil(ssd[202])
        let hdd = DriveDB.shared.match(model: "Unknown", firmware: nil, isSSD: false).specs
        XCTAssertNil(hdd[233]); XCTAssertNil(hdd[177]); XCTAssertEqual(hdd[231]?.name, "Temperature_Celsius")
        XCTAssertNil(DriveDB.shared.defaultSpecs()[231])
    }
    func testSMARTChecksumRevisionSizeAndDuplicateIDsAreRequired() {
        let pages = ATAFixtures.smartPages(ATAFixtures.healthySSD)
        let specs = DriveDB.shared.match(model: "Samsung SSD 850 EVO 500GB", firmware: nil, isSSD: true).specs
        for bad in [Array(pages.data.prefix(511)), pages.data + [0], [UInt8](repeating: 0, count: 512)] {
            XCTAssertFalse(ATAParser.isValidSMARTPage(bad))
            XCTAssertTrue(ATAParser.parseAttributes(data: bad, thresholds: nil, specs: specs).isEmpty)
            XCTAssertNil(ATAParser.parseSelfTestStatus(data: bad))
        }
        var corrupt = pages.data; corrupt[10] ^= 1
        XCTAssertTrue(ATAParser.parseAttributes(data: corrupt, thresholds: nil, specs: specs).isEmpty)
        var duplicate = pages.data; duplicate[14] = duplicate[2]
        duplicate = ATAFixtures.checksummed(duplicate)
        XCTAssertTrue(ATAParser.parseAttributes(data: duplicate, thresholds: nil, specs: specs).isEmpty)
    }
    func testInvalidThresholdPageIsUnavailableRatherThanZero() {
        let pages = ATAFixtures.smartPages(ATAFixtures.healthySSD)
        var corrupt = pages.thresholds; corrupt[3] ^= 1
        let attrs = ATAParser.parseAttributes(data: pages.data, thresholds: corrupt,
                                             specs: DriveDB.shared.match(model: "Samsung SSD 850 EVO 500GB", firmware: nil, isSSD: true).specs)
        XCTAssertFalse(attrs.isEmpty)
        XCTAssertTrue(attrs.allSatisfy { $0.threshold == nil })
        XCTAssertEqual(HealthEvaluator.evaluate(ata: reading(attributes: attrs, family: "Samsung based SSDs")).coverage, .partial)
    }
    func testReservedNormalizedValuesNeverCertifyHealth() {
        for value: UInt8 in [0, 254, 255] {
            let pages = ATAFixtures.smartPages([.init(5, current: value, worst: value, raw: 0, threshold: 10)])
            let match = DriveDB.shared.match(model: "Samsung SSD 850 EVO 500GB", firmware: nil, isSSD: true)
            let attrs = ATAParser.parseAttributes(data: pages.data, thresholds: pages.thresholds, specs: match.specs)
            XCTAssertFalse(attrs[0].hasComparableCurrent)
            XCTAssertFalse(attrs[0].failedNow)
            let report = HealthEvaluator.evaluate(ata: reading(attributes: attrs, family: match.family))
            XCTAssertNil(report.score); XCTAssertEqual(report.rating, .unknown)
        }
    }
    func testDuplicateAndReservedThresholdsBecomeUnavailable() {
        let pages = ATAFixtures.smartPages(ATAFixtures.healthySSD)
        var threshold = pages.thresholds; threshold[14] = threshold[2]
        let specs = DriveDB.shared.match(model: "Samsung SSD 850 EVO 500GB", firmware: nil, isSSD: true).specs
        let attrs = ATAParser.parseAttributes(data: pages.data, thresholds: ATAFixtures.checksummed(threshold), specs: specs)
        XCTAssertTrue(attrs.allSatisfy { $0.threshold == nil })
        threshold = pages.thresholds; threshold[3] = 255
        XCTAssertNil(ATAParser.parseAttributes(data: pages.data, thresholds: ATAFixtures.checksummed(threshold), specs: specs).first?.threshold)
    }
    func testIdentifyOptionalChecksumAndEmptyModel() {
        XCTAssertNil(ATAParser.parseIdentify([]))
        XCTAssertNil(ATAParser.parseIdentify([UInt8](repeating: 0, count: 512)))
        var block = ATAFixtures.identify(model: "TEST", serial: "S", firmware: "F", rotationRate: 1)
        block[510] = 0xa5; block = ATAFixtures.checksummed(block)
        XCTAssertNotNil(ATAParser.parseIdentify(block))
        block[7] ^= 1; XCTAssertNil(ATAParser.parseIdentify(block))
    }
    func testByteOrderIncludesReservedAndNormalizedContext() throws {
        var pages = ATAFixtures.smartPages([.init(9, current: 0x12, worst: 0x34, raw: 1, threshold: 50)])
        pages.data[13] = 0xab; pages.data = ATAFixtures.checksummed(pages.data)
        func parse(_ format: String, _ order: String? = nil) throws -> ATAAttribute {
            try XCTUnwrap(ATAParser.parseAttributes(data: pages.data, thresholds: pages.thresholds,
                specs: [9: .init(format: format, byteorder: order, name: "Power_On_Hours")]).first)
        }
        let full = try parse("raw64")
        XCTAssertEqual(full.rawValue, 0x013412)
        XCTAssertFalse(full.currentIsNormalized); XCTAssertFalse(full.worstIsNormalized)
        XCTAssertFalse(full.failedNow); XCTAssertFalse(full.failedEver)
        XCTAssertEqual(try parse("raw56").rawValue, 0xab000000000001)
        let reversed = try parse("raw48", "012345")
        XCTAssertEqual(reversed.rawValue, 0x010000000000)
        let onlyWorst = try parse("raw48", "w10")
        XCTAssertTrue(onlyWorst.currentIsNormalized); XCTAssertFalse(onlyWorst.worstIsNormalized)
        XCTAssertEqual(onlyWorst.rawValue, 0x340001)
        XCTAssertEqual(try parse("raw48", "zrv").rawValue, 0xab12)
    }
    func testMalformedOrdersAndMissingContextDoNotCrashOrGuess() {
        for order in ["", "123456", "012345012", "x"] {
            XCTAssertFalse(ATARawDecoder.decode(raw: [1,2,3,4,5,6], format: "raw48", byteorder: order).isValid)
        }
        XCTAssertFalse(ATARawDecoder.decode(raw: [], format: "raw48").isValid)
        XCTAssertFalse(ATARawDecoder.decode(raw: [1,2,3,4,5,6], format: "raw64").isValid)
        XCTAssertFalse(ATARawDecoder.decode(raw: [1,2,3,4,5,6], format: "future-format").isValid)
    }
    func testFormatDisplayParity() {
        let raw: [UInt8] = [1,2,3,4,5,6]
        func decode(_ format: String) -> ATARawValue {
            ATARawDecoder.decode(raw: raw, format: format, current: 0x12, worst: 0x34, reserved: 7)
        }
        XCTAssertEqual(decode("raw16").display, "1541 1027 513")
        XCTAssertEqual(decode("raw16(raw16)").display, "513 (1541 1027)")
        XCTAssertEqual(decode("raw16(avg16)").display, "513 (Average 1027)")
        XCTAssertEqual(decode("raw8").display, "6 5 4 3 2 1")
        XCTAssertEqual(decode("raw24(raw8)").display, "197121 (6 5 4)")
        XCTAssertEqual(decode("raw24/raw24").display, "394500/197121")
        XCTAssertEqual(decode("loadunload").display, decode("raw24/raw24").display)
        XCTAssertEqual(decode("raw24/raw32").display, "460293/67305985")
        XCTAssertEqual(decode("hex56").display, "0x07060504030201")
        XCTAssertEqual(decode("hex64").display, "0x0605040302013412")
        XCTAssertEqual(decode("raw64").counter, 0x0605040302013412)
    }
    func testTimeFormatsRetainCounterAndInterpretPrimaryHours() {
        XCTAssertEqual(ATARawDecoder.decode(raw: [150,0,0,0,3,0], format: "minutes").display, "2h+30m (3)")
        let subhour = ATARawDecoder.decode(raw: [7,0,0,0,0x40,0xe2], format: "msec24hour32", reserved: 1)
        XCTAssertEqual(subhour.display, "7h+02m+03.456s")
        XCTAssertEqual(subhour.value, 7)
        XCTAssertEqual(ATARawDecoder.decode(raw: [0x10,0x0e,0,0,0,0], format: "seconds").value, 1)
    }
    func testSignedTemperatureAndMultipleMinMaxLayouts() {
        for raw: [UInt8] in [[35,0,20,50,0,0], [35,20,50,0,0,0], [35,0,20,0,50,0]] {
            let decoded = ATARawDecoder.decode(raw: raw, format: "tempminmax")
            XCTAssertEqual(decoded.temperatureCelsius, 35)
            XCTAssertEqual(decoded.display, "35 (Min/Max 20/50)")
        }
        let negative = ATARawDecoder.decode(raw: [251,255,0,0,0,0], format: "tempminmax")
        XCTAssertEqual(negative.temperatureCelsius, -5)
        XCTAssertEqual(negative.display, "-5")
        XCTAssertNil(ATARawDecoder.decode(raw: [35,5,5,5,5,5], format: "tempminmax").temperatureCelsius)
    }
    func testEveryBundledFormatHasDecoderSupport() {
        let db = DriveDB.shared
        for spec in db.entries.flatMap({ Array(($0.attrs ?? [:]).values) }) + Array(db.defaultSpecs().values) {
            let decoded = ATARawDecoder.decode(raw: [0,0,0,0,0,0], format: spec.format,
                                               byteorder: spec.byteorder, current: 100, worst: 100, reserved: 0)
            XCTAssertTrue(decoded.isValid, "Unsupported bundled format \(spec.format):\(spec.byteorder ?? "default")")
        }
    }
    func testSamsungFirmwareCorrections() {
        let pages = ATAFixtures.smartPages([], selfTestByte: 0xf0)
        XCTAssertTrue(ATAParser.parseSelfTestStatus(data: pages.data)?.inProgress == true)
        XCTAssertFalse(ATAParser.parseSelfTestStatus(data: pages.data, firmwareFixes: ["samsung3"])?.inProgress == true)
        var log = [UInt8](repeating: 0, count: 512)
        log[0] = 1; log[2] = 0x70; log[3] = 2; log[4] = 123; log[509] = 1
        log = ATAFixtures.checksummed(log)
        let result = ATAParser.parseSelfTestLog(log, firmwareFixes: ["samsung"])
        XCTAssertEqual(result.first?.testType, 2); XCTAssertEqual(result.first?.statusCode, 7)
        XCTAssertEqual(result.first?.powerOnHours, 123)
        XCTAssertEqual(DriveDB.shared.match(model: "SAMSUNG SV4012H", firmware: "RM100-08", isSSD: false).firmwareFixes, ["samsung"])
        XCTAssertEqual(DriveDB.shared.match(model: "SAMSUNG SP1603N", firmware: "VF100-37", isSSD: false).firmwareFixes, ["samsung3"])
        XCTAssertEqual(DriveDB.shared.match(model: "INTEL SSDSA2BW080G3", firmware: nil, isSSD: true).firmwareFixes, ["nologdir"])
    }
    func testCounterUnitConversionAndSumNeverWrap() {
        let sample = reading(attributes: [attribute(241, "Host_Writes_GiB", raw: UInt64.max),
                                          attribute(5, "Reallocated_Sector_Ct", raw: UInt64.max),
                                          attribute(187, "Reported_Uncorrect", raw: 1)])
        XCTAssertNil(DriveReading.ata(sample).bytesWritten)
        XCTAssertNil(DriveReading.ata(sample).defectCount)
        XCTAssertEqual(DriveReading.ata(reading(attributes: [attribute(246, "Total_LBAs_Written", raw: 3)])).bytesWritten, 1536)
        XCTAssertNil(DriveReading.ata(reading(attributes: [attribute(241, "NAND_GiB_Written", raw: 3)])).bytesWritten)
    }
    func testZeroNVMeLogDoesNotMeanPerfectHealthOrNegativeTemperature() {
        let smart = NVMeSMARTProvider.decode(log: MDNVMeSMARTLog())
        XCTAssertNil(smart.temperatureCelsius)
        let report = HealthEvaluator.evaluate(nvme: .init(controller: NVMeSMARTProvider.decode(identify: MDNVMeIdentifyController()), smart: smart))
        XCTAssertNil(report.score); XCTAssertNil(report.lifetimeLeftPercent)
        XCTAssertEqual(report.rating, .unknown); XCTAssertEqual(report.coverage, .unavailable)
    }
    func testNVMeMissingIdentifyPreservesKnownCriticalWarning() {
        var log = MDNVMeSMARTLog(); log.availableSpare = 100; log.criticalWarning = 8
        let report = HealthEvaluator.evaluate(nvme: .init(controller: NVMeSMARTProvider.decode(identify: MDNVMeIdentifyController()),
                                                         smart: NVMeSMARTProvider.decode(log: log)))
        XCTAssertEqual(report.coverage, .partial); XCTAssertNil(report.score)
        XCTAssertEqual(report.rating, .failed)
    }
    func testInvalidPercentAndImplausibleTemperaturesAreUnknown() {
        var log = MDNVMeSMARTLog(); log.availableSpare = 255
        let report = HealthEvaluator.evaluate(nvme: .init(controller: NVMeSMARTProvider.decode(identify: MDNVMeIdentifyController()),
                                                         smart: NVMeSMARTProvider.decode(log: log)))
        XCTAssertEqual(report.coverage, .unavailable)
        log.availableSpare = 100; log.temperature = (1, 0)
        XCTAssertNil(NVMeSMARTProvider.decode(log: log).temperatureCelsius)
        let temp = ATARawDecoder.decode(raw: [255,255,0,0,0,0], format: "temp10x")
        XCTAssertFalse(temp.isValid); XCTAssertNil(temp.temperatureCelsius)
    }
    func testNVMe128BitCountersDoNotTruncateIntoHistoryOrScaleOverflow() {
        var log = MDNVMeSMARTLog(); log.availableSpare = 100
        withUnsafeMutableBytes(of: &log.dataUnitsWritten) { $0[8] = 1; $0[0] = 4 }
        withUnsafeMutableBytes(of: &log.mediaErrors) { $0[9] = 1 }
        withUnsafeMutableBytes(of: &log.dataUnitsRead) { $0.storeBytes(of: UInt64.max, as: UInt64.self) }
        let smart = NVMeSMARTProvider.decode(log: log)
        XCTAssertNil(smart.bytesWritten); XCTAssertNil(smart.bytesRead); XCTAssertNil(smart.knownMediaErrors)
        XCTAssertTrue(smart.unavailableCounters.contains("mediaErrors"))
        let report = HealthEvaluator.evaluate(nvme: .init(controller: NVMeSMARTProvider.decode(identify: MDNVMeIdentifyController()), smart: smart))
        XCTAssertNil(report.score); XCTAssertEqual(report.rating, .failing)
        XCTAssertTrue(report.issues.contains { $0.id == "nvme.media-errors" && $0.severity == .critical })
    }
}
