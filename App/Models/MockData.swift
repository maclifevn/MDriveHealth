/*
 * MockData.swift — synthetic snapshots for previews and UI-state testing.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

enum MockData {
    static func nvmeReading(percentageUsed: UInt8 = 4,
                            criticalWarning: NVMeCriticalWarning = [],
                            mediaErrors: UInt64 = 0,
                            spare: UInt8 = 100) -> NVMeReading {
        NVMeReading(
            controller: NVMeControllerInfo(
                model: "APPLE SSD AP0512Z", serialNumber: "MOCK123456",
                firmwareRevision: "236", ieeeOUI: "00-05-CD", controllerID: 0,
                specVersion: "1.3.0", totalCapacityBytes: 500_277_792_768,
                unallocatedCapacityBytes: 0, warningTempKelvin: 357,
                criticalTempKelvin: 373, namespaceCount: 1),
            smart: NVMeSMARTSnapshot(
                capturedAt: Date(), criticalWarning: criticalWarning,
                temperatureKelvin: 310, availableSpare: spare,
                availableSpareThreshold: 10, percentageUsed: percentageUsed,
                dataUnitsRead: 232_823_305, dataUnitsWritten: 140_420_389,
                hostReadCommands: 4_942_474_328, hostWriteCommands: 1_621_093_714,
                controllerBusyTimeMinutes: 120, powerCycles: 289,
                powerOnHours: 1_726, unsafeShutdowns: 43, mediaErrors: mediaErrors,
                errorLogEntries: 0, warningTempTimeMinutes: 0,
                criticalTempTimeMinutes: 0, temperatureSensorsKelvin: [312, 305])
        )
    }

    static let healthyInternal: DriveSnapshot = {
        let drive = DriveInfo(
            registryEntryID: 1, bsdName: "disk0", model: "APPLE SSD AP0512Z",
            serialNumber: "MOCK123456", firmwareRevision: "236",
            sizeBytes: 500_277_792_768, interconnect: "Apple Fabric",
            location: "Internal", isSolidState: true, smartInterface: .nvme)
        let reading = DriveReading.nvme(nvmeReading())
        return DriveSnapshot(drive: drive, reading: reading,
                             health: reading.evaluateHealth(),
                             lastError: nil, lastUpdated: Date())
    }()

    static let failingExternal: DriveSnapshot = {
        let drive = DriveInfo(
            registryEntryID: 2, bsdName: "disk2", model: "WDC WD20SPZX-00UA7T0",
            serialNumber: "WD-MOCK", firmwareRevision: "01.0", sizeBytes: 2_000_398_934_016,
            interconnect: "SATA", location: "External", isSolidState: false,
            smartInterface: .ata)
        let reading = DriveReading.nvme(
            nvmeReading(percentageUsed: 97, criticalWarning: [.spareBelowThreshold],
                        mediaErrors: 24, spare: 4))
        return DriveSnapshot(drive: drive, reading: reading,
                             health: reading.evaluateHealth(),
                             lastError: nil, lastUpdated: Date())
    }()
}
