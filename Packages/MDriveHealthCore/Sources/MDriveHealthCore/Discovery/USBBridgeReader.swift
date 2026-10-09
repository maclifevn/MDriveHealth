/*
 * USBBridgeReader.swift — USB enclosure/bridge details for external drives.
 * Answers the two questions every USB-drive owner asks: "what chip is in
 * this enclosure?" and "why is it slow / why no SMART?" — by walking the
 * IORegistry parent chain from the block-storage device up to the
 * IOUSBHostDevice node.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit

public struct USBBridgeInfo: Sendable, Codable, Hashable {
    public let vendorName: String?
    public let productName: String?
    public let vendorID: Int?
    public let productID: Int?
    /// Negotiated (not theoretical) link speed in Mb/s: 480 on a USB 2 port
    /// or cable even when drive and Mac both do 10 Gb/s.
    public let linkSpeedMbps: Int?
    /// USB Attached SCSI (UASP) — command queueing, noticeably faster than
    /// the old Bulk-Only Transport.
    public let usesUAS: Bool
}

public enum USBBridgeReader {
    /// nil when the drive has no USB ancestor (internal drives, Thunderbolt).
    public static func bridgeInfo(forDriveRegistryEntryID registryEntryID: UInt64)
        -> USBBridgeInfo? {
        var entry = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard entry != 0 else { return nil }

        var sawUAS = false
        // Bounded walk: storage stacks are ~6-10 nodes deep to the USB device.
        for _ in 0..<16 {
            var className = [CChar](repeating: 0, count: 128)
            if IOObjectGetClass(entry, &className) == KERN_SUCCESS {
                let name = String(cString: className)
                if name.localizedCaseInsensitiveContains("UAS") { sawUAS = true }
                if name == "IOUSBHostDevice" || name == "IOUSBDevice" {
                    let info = readDevice(entry, usesUAS: sawUAS)
                    IOObjectRelease(entry)
                    return info
                }
            }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard kr == KERN_SUCCESS, parent != 0 else { return nil }
            entry = parent
        }
        IOObjectRelease(entry)
        return nil
    }

    /// IOUSBHostFamily connection-speed enum → Mb/s. Pure, unit-tested.
    static func speedMbps(fromUSBSpeedValue value: Int) -> Int? {
        switch value {
        case 1: return 2        // low speed (1.5 Mb/s, rounded)
        case 2: return 12       // full speed
        case 3: return 480      // high speed — USB 2.0
        case 4: return 5_000    // SuperSpeed — USB 3.x Gen 1
        case 5: return 10_000   // SuperSpeed+ — Gen 2
        case 6: return 20_000   // SuperSpeed+ — Gen 2x2
        default: return nil
        }
    }

    private static func readDevice(_ entry: io_registry_entry_t,
                                   usesUAS: Bool) -> USBBridgeInfo {
        func string(_ key: String) -> String? {
            guard let value = IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
            return value.takeRetainedValue() as? String
        }
        func int(_ key: String) -> Int? {
            guard let value = IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0) else { return nil }
            return (value.takeRetainedValue() as? NSNumber)?.intValue
        }
        // Key names differ across macOS releases — try the known spellings.
        let speedValue = int("USB Device Speed") ?? int("USBSpeed") ?? int("Device Speed")
        return USBBridgeInfo(
            vendorName: string("USB Vendor Name") ?? string("kUSBVendorString"),
            productName: string("USB Product Name") ?? string("kUSBProductString"),
            vendorID: int("idVendor"),
            productID: int("idProduct"),
            linkSpeedMbps: speedValue.flatMap(speedMbps(fromUSBSpeedValue:)),
            usesUAS: usesUAS)
    }
}
