/*
 * NVMeModels.swift — Swift models for NVMe identify + SMART/health log data.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

/// Bits of the NVMe SMART "critical warning" byte (NVMe spec, log page 02h).
public struct NVMeCriticalWarning: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Available spare has fallen below the threshold.
    public static let spareBelowThreshold = NVMeCriticalWarning(rawValue: 1 << 0)
    /// Temperature outside operating thresholds.
    public static let temperatureError = NVMeCriticalWarning(rawValue: 1 << 1)
    /// NVM subsystem reliability degraded due to media/internal errors.
    public static let reliabilityDegraded = NVMeCriticalWarning(rawValue: 1 << 2)
    /// Media has been placed in read-only mode.
    public static let mediaReadOnly = NVMeCriticalWarning(rawValue: 1 << 3)
    /// Volatile memory backup device has failed.
    public static let volatileBackupFailed = NVMeCriticalWarning(rawValue: 1 << 4)
    /// Persistent memory region read-only/unreliable.
    public static let persistentMemoryReadOnly = NVMeCriticalWarning(rawValue: 1 << 5)
}

/// Decoded NVMe Identify Controller data.
public struct NVMeControllerInfo: Sendable, Codable, Hashable {
    public let model: String
    public let serialNumber: String
    public let firmwareRevision: String
    public let ieeeOUI: String
    public let controllerID: UInt16
    /// NVMe spec version implemented by the controller, e.g. "1.4.0"; nil when
    /// not reported (some Apple controllers report 0).
    public let specVersion: String?
    public let totalCapacityBytes: UInt64
    public let unallocatedCapacityBytes: UInt64
    /// Warning composite temperature threshold (Kelvin); 0 when not reported.
    public let warningTempKelvin: UInt16
    /// Critical composite temperature threshold (Kelvin); 0 when not reported.
    public let criticalTempKelvin: UInt16
    public let namespaceCount: UInt32

    public init(model: String, serialNumber: String, firmwareRevision: String,
                ieeeOUI: String, controllerID: UInt16, specVersion: String?,
                totalCapacityBytes: UInt64, unallocatedCapacityBytes: UInt64,
                warningTempKelvin: UInt16, criticalTempKelvin: UInt16,
                namespaceCount: UInt32) {
        self.model = model
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.ieeeOUI = ieeeOUI
        self.controllerID = controllerID
        self.specVersion = specVersion
        self.totalCapacityBytes = totalCapacityBytes
        self.unallocatedCapacityBytes = unallocatedCapacityBytes
        self.warningTempKelvin = warningTempKelvin
        self.criticalTempKelvin = criticalTempKelvin
        self.namespaceCount = namespaceCount
    }
}

/// Decoded NVMe SMART / Health Information log (log page 02h).
public struct NVMeSMARTSnapshot: Sendable, Codable, Hashable {
    public let capturedAt: Date
    public let criticalWarning: NVMeCriticalWarning
    /// Composite controller temperature, Kelvin.
    public let temperatureKelvin: UInt16
    /// Remaining spare capacity, percent of initial.
    public let availableSpare: UInt8
    /// Spare threshold below which a warning is raised, percent.
    public let availableSpareThreshold: UInt8
    /// Vendor estimate of endurance used, percent; may exceed 100.
    public let percentageUsed: UInt8
    /// 1 unit = 1000 × 512 bytes.
    public let dataUnitsRead: UInt64
    public let dataUnitsWritten: UInt64
    public let hostReadCommands: UInt64
    public let hostWriteCommands: UInt64
    public let controllerBusyTimeMinutes: UInt64
    public let powerCycles: UInt64
    public let powerOnHours: UInt64
    public let unsafeShutdowns: UInt64
    public let mediaErrors: UInt64
    public let errorLogEntries: UInt64
    public let warningTempTimeMinutes: UInt32
    public let criticalTempTimeMinutes: UInt32
    /// Additional temperature sensors, Kelvin; zeros for absent sensors.
    public let temperatureSensorsKelvin: [UInt16]

    /// Unreported (0/FFFFh) or implausible composite temperatures are unknown.
    public var temperatureCelsius: Int? {
        guard (213...473).contains(temperatureKelvin) else { return nil }
        return Int(temperatureKelvin) - 273
    }
    public let unavailableCounters: Set<String>
    public func counterValue(_ field: String) -> UInt64? {
        guard hasUsableHealthData, !unavailableCounters.contains(field) else { return nil }
        switch field {
        case "dataUnitsRead": return dataUnitsRead
        case "dataUnitsWritten": return dataUnitsWritten
        case "hostReadCommands": return hostReadCommands
        case "hostWriteCommands": return hostWriteCommands
        case "controllerBusyTimeMinutes": return controllerBusyTimeMinutes
        case "powerCycles": return powerCycles
        case "powerOnHours": return powerOnHours
        case "unsafeShutdowns": return unsafeShutdowns
        case "mediaErrors": return mediaErrors
        case "errorLogEntries": return errorLogEntries
        default: return nil
        }
    }
    public func counterDisplay(_ field: String) -> String { counterValue(field).map(String.init) ?? "—" }
    public var knownMediaErrors: UInt64? { unavailableCounters.contains("mediaErrors") ? nil : mediaErrors }
    public var bytesRead: UInt64? { scaled(dataUnitsRead, field: "dataUnitsRead") }
    public var bytesWritten: UInt64? { scaled(dataUnitsWritten, field: "dataUnitsWritten") }
    private func scaled(_ units: UInt64, field: String) -> UInt64? {
        guard !unavailableCounters.contains(field) else { return nil }
        let value = units.multipliedReportingOverflow(by: 512_000)
        return value.overflow ? nil : value.partialValue
    }
    public var hasUsableHealthData: Bool {
        availableSpare <= 100 && availableSpareThreshold <= 100 &&
        (criticalWarning.rawValue != 0 || temperatureCelsius != nil || availableSpare > 0 ||
         availableSpareThreshold > 0 || percentageUsed > 0 || powerOnHours > 0 ||
         dataUnitsRead > 0 || dataUnitsWritten > 0 || mediaErrors > 0 || powerCycles > 0 || !unavailableCounters.isEmpty)
    }

    public init(capturedAt: Date, criticalWarning: NVMeCriticalWarning,
                temperatureKelvin: UInt16, availableSpare: UInt8,
                availableSpareThreshold: UInt8, percentageUsed: UInt8,
                dataUnitsRead: UInt64, dataUnitsWritten: UInt64,
                hostReadCommands: UInt64, hostWriteCommands: UInt64,
                controllerBusyTimeMinutes: UInt64, powerCycles: UInt64,
                powerOnHours: UInt64, unsafeShutdowns: UInt64,
                mediaErrors: UInt64, errorLogEntries: UInt64,
                warningTempTimeMinutes: UInt32, criticalTempTimeMinutes: UInt32,
                temperatureSensorsKelvin: [UInt16], unavailableCounters: Set<String> = []) {
        self.unavailableCounters = unavailableCounters
        self.capturedAt = capturedAt
        self.criticalWarning = criticalWarning
        self.temperatureKelvin = temperatureKelvin
        self.availableSpare = availableSpare
        self.availableSpareThreshold = availableSpareThreshold
        self.percentageUsed = percentageUsed
        self.dataUnitsRead = dataUnitsRead
        self.dataUnitsWritten = dataUnitsWritten
        self.hostReadCommands = hostReadCommands
        self.hostWriteCommands = hostWriteCommands
        self.controllerBusyTimeMinutes = controllerBusyTimeMinutes
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
        self.mediaErrors = mediaErrors
        self.errorLogEntries = errorLogEntries
        self.warningTempTimeMinutes = warningTempTimeMinutes
        self.criticalTempTimeMinutes = criticalTempTimeMinutes
        self.temperatureSensorsKelvin = temperatureSensorsKelvin
    }
}

/// A complete NVMe probe result.
public struct NVMeReading: Sendable, Codable, Hashable {
    public let controller: NVMeControllerInfo
    public let smart: NVMeSMARTSnapshot

    public init(controller: NVMeControllerInfo, smart: NVMeSMARTSnapshot) {
        self.controller = controller
        self.smart = smart
    }
}
