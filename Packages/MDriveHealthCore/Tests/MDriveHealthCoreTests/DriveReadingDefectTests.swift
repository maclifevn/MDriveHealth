/*
 * DriveReadingDefectTests.swift — unified defect counters on DriveReading.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class DriveReadingDefectTests: XCTestCase {
    private func ataAttribute(_ id: UInt8, raw: UInt64) -> ATAAttribute {
        ATAAttribute(attributeID: id, name: [5: "Reallocated_Sector_Ct", 187: "Reported_Uncorrect", 197: "Current_Pending_Sector", 198: "Offline_Uncorrectable", 199: "UDMA_CRC_Error_Count"][id] ?? "Unknown_Attribute", flags: 0x0002,
                     current: 100, worst: 100, threshold: 0,
                     rawBytes: [], rawValue: raw, rawDisplay: "\(raw)")
    }

    private func ataReading(attributes: [ATAAttribute]) -> DriveReading {
        .ata(ATASMARTReading(
            capturedAt: Date(), identify: nil, attributes: attributes,
            overallFailurePredicted: false, selfTest: nil,
            driveFamily: nil, driveWarning: nil))
    }

    func testATADefectCountSumsPermanentDefectAttributes() {
        let reading = ataReading(attributes: [
            ataAttribute(5, raw: 4),
            ataAttribute(187, raw: 2),
            ataAttribute(197, raw: 7),
            ataAttribute(198, raw: 1),
            ataAttribute(199, raw: 99), // CRC errors are not media defects
        ])
        XCTAssertEqual(reading.defectCount, 7, "5 + 187 + 198")
        XCTAssertEqual(reading.pendingSectors, 7)
        XCTAssertEqual(reading.dangerousDefectTotal, 14)
    }

    func testATAReportsKnownCountAndLeavesMissingPendingUnknown() {
        let reading = ataReading(attributes: [ataAttribute(5, raw: 3)])
        XCTAssertEqual(reading.defectCount, 3)
        XCTAssertNil(reading.pendingSectors,
                     "attribute 197 absent → pending is unknown, not 0")
        XCTAssertEqual(reading.dangerousDefectTotal, 3)
    }

    func testNVMeDefectCountIsMediaErrors() {
        let reading = DriveReading.nvme(NVMeReading(
            controller: NVMeControllerInfo(
                model: "T", serialNumber: "S", firmwareRevision: "F", ieeeOUI: "0",
                controllerID: 0, specVersion: nil, totalCapacityBytes: 0,
                unallocatedCapacityBytes: 0, warningTempKelvin: 0,
                criticalTempKelvin: 0, namespaceCount: 1),
            smart: NVMeSMARTSnapshot(
                capturedAt: Date(), criticalWarning: [], temperatureKelvin: 300,
                availableSpare: 100, availableSpareThreshold: 10, percentageUsed: 0,
                dataUnitsRead: 0, dataUnitsWritten: 0, hostReadCommands: 0,
                hostWriteCommands: 0, controllerBusyTimeMinutes: 0, powerCycles: 0,
                powerOnHours: 0, unsafeShutdowns: 0, mediaErrors: 12,
                errorLogEntries: 0, warningTempTimeMinutes: 0,
                criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [])))
        XCTAssertEqual(reading.defectCount, 12)
        XCTAssertNil(reading.pendingSectors)
        XCTAssertEqual(reading.dangerousDefectTotal, 12)
    }
}
