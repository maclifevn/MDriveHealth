/*
 * HealthEvaluatorTests.swift
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class HealthEvaluatorTests: XCTestCase {

    // MARK: - Helpers

    private func nvmeReading(
        criticalWarning: NVMeCriticalWarning = [],
        tempKelvin: UInt16 = 312,
        spare: UInt8 = 100, spareThreshold: UInt8 = 10,
        percentageUsed: UInt8 = 3,
        mediaErrors: UInt64 = 0,
        warningTemp: UInt16 = 0, criticalTemp: UInt16 = 0
    ) -> NVMeReading {
        NVMeReading(
            controller: NVMeControllerInfo(
                model: "TEST SSD", serialNumber: "S/N", firmwareRevision: "1.0",
                ieeeOUI: "00-00-00", controllerID: 0, specVersion: nil,
                totalCapacityBytes: 0, unallocatedCapacityBytes: 0,
                warningTempKelvin: warningTemp, criticalTempKelvin: criticalTemp,
                namespaceCount: 1),
            smart: NVMeSMARTSnapshot(
                capturedAt: Date(), criticalWarning: criticalWarning,
                temperatureKelvin: tempKelvin, availableSpare: spare,
                availableSpareThreshold: spareThreshold, percentageUsed: percentageUsed,
                dataUnitsRead: 1, dataUnitsWritten: 1, hostReadCommands: 1,
                hostWriteCommands: 1, controllerBusyTimeMinutes: 0, powerCycles: 10,
                powerOnHours: 100, unsafeShutdowns: 0, mediaErrors: mediaErrors,
                errorLogEntries: 0, warningTempTimeMinutes: 0,
                criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [])
        )
    }

    private func ataReading(_ seeds: [ATAFixtures.AttributeSeed], isSSD: Bool,
                            overallFailing: Bool? = false) -> ATASMARTReading {
        let (data, thresholds) = ATAFixtures.smartPages(seeds)
        let model = isSSD ? "Samsung SSD 850 EVO 500GB" : "ST2000LM007-1R8174"
        let match = DriveDB.shared.match(model: model, firmware: nil, isSSD: isSSD)
        let attrs = ATAParser.parseAttributes(data: data, thresholds: thresholds, specs: match.specs)
        return ATASMARTReading(
            capturedAt: Date(),
            identify: ATAIdentifyInfo(model: model, serialNumber: "S", firmwareRevision: "F",
                                      rotationRate: isSSD ? 1 : 7200),
            attributes: attrs, overallFailurePredicted: overallFailing,
            selfTest: nil, driveFamily: match.family, driveWarning: nil)
    }

    // MARK: - NVMe

    func testHealthyNVMeIsGood() {
        let report = HealthEvaluator.evaluate(nvme: nvmeReading())
        XCTAssertEqual(report.rating, .good)
        XCTAssertEqual(report.score, 100)
        XCTAssertEqual(report.lifetimeLeftPercent, 97)
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testWornNVMeLosesLifetime() {
        let report = HealthEvaluator.evaluate(nvme: nvmeReading(percentageUsed: 95))
        XCTAssertEqual(report.lifetimeLeftPercent, 5)
        XCTAssertTrue(report.issues.contains { $0.id == "nvme.wear.high" })
        XCTAssertLessThan(report.score ?? 101, 100)
    }

    func testSpareBelowThresholdIsFailing() {
        let report = HealthEvaluator.evaluate(
            nvme: nvmeReading(criticalWarning: [.spareBelowThreshold], spare: 5, spareThreshold: 10))
        XCTAssertGreaterThanOrEqual(report.rating, .failing)
        XCTAssertTrue(report.issues.contains { $0.id == "nvme.spare" && $0.severity == .critical })
    }

    func testReadOnlyMediaIsFailed() {
        let report = HealthEvaluator.evaluate(
            nvme: nvmeReading(criticalWarning: [.mediaReadOnly, .reliabilityDegraded]))
        XCTAssertEqual(report.rating, .failed)
    }

    func testMediaErrorsProduceWarning() {
        let report = HealthEvaluator.evaluate(nvme: nvmeReading(mediaErrors: 4))
        XCTAssertEqual(report.rating, .warning)
        XCTAssertTrue(report.issues.contains { $0.id == "nvme.media-errors" })
    }

    func testHotNVMeAgainstIdentifyThresholds() {
        let report = HealthEvaluator.evaluate(
            nvme: nvmeReading(tempKelvin: 360, warningTemp: 357, criticalTemp: 373))
        XCTAssertTrue(report.issues.contains { $0.id == "nvme.temperature.high" })
    }

    // MARK: - ATA

    func testHealthyATASSDIsGood() {
        let report = HealthEvaluator.evaluate(
            ata: ataReading(ATAFixtures.healthySSD, isSSD: true))
        XCTAssertEqual(report.rating, .good)
        XCTAssertEqual(report.lifetimeLeftPercent, 95, "wear from attr 177 normalized value")
        XCTAssertTrue(report.issues.isEmpty)
    }

    func testDyingHDDIsFailing() {
        let report = HealthEvaluator.evaluate(
            ata: ataReading(ATAFixtures.dyingHDD, isSSD: false))
        XCTAssertGreaterThanOrEqual(report.rating, .failing)
        XCTAssertLessThan(report.score ?? 101, 30)
        XCTAssertTrue(report.issues.contains { $0.id == "ata.5.tripped" })   // prefail tripped
        XCTAssertTrue(report.issues.contains { $0.id == "ata.5.raw" })       // realloc raw
        XCTAssertTrue(report.issues.contains { $0.id == "ata.197.raw" })     // pending
        XCTAssertNil(report.lifetimeLeftPercent, "HDD has no SSD lifetime")
    }

    func testSMARTOverallFailingCapsRating() {
        let report = HealthEvaluator.evaluate(
            ata: ataReading(ATAFixtures.healthySSD, isSSD: true, overallFailing: true))
        XCTAssertGreaterThanOrEqual(report.rating, .failing)
        XCTAssertTrue(report.issues.contains { $0.id == "ata.smart-status" })
    }

    func testCRCOnlyIsAdvisoryCable() {
        let seeds: [ATAFixtures.AttributeSeed] = [
            .init(5, flags: 0x0033, current: 100, worst: 100, raw: 0, threshold: 10),
            .init(199, flags: 0x003E, current: 200, worst: 200, raw: 3, threshold: 0),
        ]
        let report = HealthEvaluator.evaluate(ata: ataReading(seeds, isSSD: false))
        XCTAssertEqual(report.rating, .good, "a few CRC errors are cable advisories, not drive damage")
        XCTAssertTrue(report.issues.contains { $0.id == "ata.199.raw" && $0.severity == .advisory })
    }

    func testIssuesSortedMostSevereFirst() {
        let report = HealthEvaluator.evaluate(
            ata: ataReading(ATAFixtures.dyingHDD, isSSD: false))
        let severities = report.issues.map(\.severity)
        XCTAssertEqual(severities, severities.sorted(by: >))
    }
}
