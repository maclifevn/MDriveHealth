/*
 * BatteryReader.swift — battery health via the AppleSmartBattery service.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit

public struct BatteryInfo: Sendable, Codable, Hashable {
    public let cycleCount: Int
    /// Factory design capacity, mAh.
    public let designCapacitymAh: Int
    /// Current full-charge capacity, mAh.
    public let maxCapacitymAh: Int
    /// Present charge, mAh.
    public let currentCapacitymAh: Int
    public let temperatureCelsius: Double?
    public let isCharging: Bool
    public let externalPowerConnected: Bool
    public let serialNumber: String?

    /// Full-charge capacity as a share of design capacity, percent.
    public var healthPercent: Int {
        guard designCapacitymAh > 0 else { return 0 }
        return min(100, Int((Double(maxCapacitymAh) / Double(designCapacitymAh) * 100).rounded()))
    }

    /// Charge level 0-100 relative to current full capacity.
    public var chargePercent: Int {
        guard maxCapacitymAh > 0 else { return 0 }
        return min(100, Int((Double(currentCapacitymAh) / Double(maxCapacitymAh) * 100).rounded()))
    }
}

public enum BatteryReader {
    /// Returns nil on Macs without a battery.
    public static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
            let props = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        func int(_ keys: String...) -> Int? {
            for key in keys {
                if let value = props[key] as? Int { return value }
                if let value = props[key] as? NSNumber { return value.intValue }
            }
            return nil
        }

        guard let design = int("DesignCapacity"), design > 0 else { return nil }
        // Apple Silicon reports real mAh in AppleRaw*/NominalChargeCapacity;
        // plain MaxCapacity is a percentage there.
        let maxCapacity = int("AppleRawMaxCapacity", "NominalChargeCapacity") ?? 0
        let current = int("AppleRawCurrentCapacity", "CurrentCapacity") ?? 0

        // Temperature is reported in centi-degrees Celsius.
        let temperature = int("Temperature").map { Double($0) / 100 }
        let virtualTemp = (temperature ?? 0) > 200 // guard nonsense units
        return BatteryInfo(
            cycleCount: int("CycleCount") ?? 0,
            designCapacitymAh: design,
            maxCapacitymAh: maxCapacity,
            currentCapacitymAh: current,
            temperatureCelsius: virtualTemp ? nil : temperature,
            isCharging: props["IsCharging"] as? Bool ?? false,
            externalPowerConnected: props["ExternalConnected"] as? Bool ?? false,
            serialNumber: props["BatterySerialNumber"] as? String
                ?? props["Serial"] as? String
        )
    }
}
