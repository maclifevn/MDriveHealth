/*
 * SensorsReader.swift — temperature sensors via IOHIDEventSystemClient
 * (Apple Silicon). Best-effort: returns an empty list when unavailable.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import CSMART

public struct TemperatureSensor: Sendable, Codable, Hashable, Identifiable {
    public let name: String
    public let celsius: Double
    public var id: String { name }
}

/// Stable identifiers; translated captions must never become grouping keys.
public enum TemperatureSensorGroup: String, Sendable, Codable, CaseIterable {
    case processor, graphics, storage, battery, power, other

    public func displayName(locale: Locale = .current) -> String {
        // String(localized:locale:) uses locale for formatting, while the
        // bundle's preferred language still follows the process. Explicitly
        // select the resource language to honor SwiftUI's locale environment.
        let language = locale.language.languageCode?.identifier ?? "vi"
        let bundle = Bundle.module.url(forResource: language, withExtension: "lproj")
            .flatMap { Bundle(url: $0) } ?? Bundle.module
        switch self {
        case .processor: return String(localized: "sensor.group.processor", defaultValue: "CPU/SOC", bundle: bundle, locale: locale)
        case .graphics: return String(localized: "sensor.group.graphics", defaultValue: "GPU", bundle: bundle, locale: locale)
        case .storage: return String(localized: "sensor.group.storage", defaultValue: "SSD (NAND)", bundle: bundle, locale: locale)
        case .battery: return String(localized: "sensor.group.battery", defaultValue: "Pin", bundle: bundle, locale: locale)
        case .power: return String(localized: "sensor.group.power", defaultValue: "Nguồn", bundle: bundle, locale: locale)
        case .other: return String(localized: "sensor.group.other", defaultValue: "Khác", bundle: bundle, locale: locale)
        }
    }
}

public enum SensorsReader {
    /// Reads all HID temperature sensors (SOC, NAND, battery... on M-series).
    public static func readTemperatures() -> [TemperatureSensor] {
        guard let unmanagedClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return []
        }
        let client = unmanagedClient.takeRetainedValue()
        let matching: [String: Int] = [
            "PrimaryUsagePage": Int(kMDHIDUsagePageAppleVendor),
            "PrimaryUsage": Int(kMDHIDUsageAppleVendorTemperatureSensor),
        ]
        IOHIDEventSystemClientSetMatching(client, matching as CFDictionary)
        guard let services = IOHIDEventSystemClientCopyServices(client) as NSArray?
        else { return [] }

        var sensors: [TemperatureSensor] = []
        for element in services {
            let service = element as! IOHIDServiceClient
            let value = MDHIDServiceReadTemperature(service)
            guard value > 0, value < 130 else { continue }
            let name = (IOHIDServiceClientCopyProperty(
                service, "Product" as CFString) as? String) ?? "Sensor"
            sensors.append(TemperatureSensor(name: name, celsius: value))
        }
        return sensors.sorted { $0.name < $1.name }
    }

    /// Groups raw sensors into human-friendly buckets and averages them.
    public static func summarize(_ sensors: [TemperatureSensor])
        -> [(group: TemperatureSensorGroup, celsius: Double)] {
        var buckets: [TemperatureSensorGroup: [Double]] = [:]
        for sensor in sensors {
            guard sensor.celsius.isFinite, sensor.celsius > 0, sensor.celsius < 130 else { continue }
            let name = sensor.name.lowercased()
            let group: TemperatureSensorGroup
            if name.contains("pmu") && name.contains("tdie") { group = .processor }
            else if name.contains("soc") || name.contains("cpu") { group = .processor }
            else if name.contains("gpu") { group = .graphics }
            else if name.contains("nand") || name.contains("ans") { group = .storage }
            else if name.contains("batt") || name.contains("gas gauge") { group = .battery }
            else if name.contains("pmgr") || name.contains("power") { group = .power }
            else { group = .other }
            buckets[group, default: []].append(sensor.celsius)
        }
        return TemperatureSensorGroup.allCases.compactMap { group in
            guard let values = buckets[group], !values.isEmpty else { return nil }
            return (group, values.reduce(0, +) / Double(values.count))
        }
    }
}
