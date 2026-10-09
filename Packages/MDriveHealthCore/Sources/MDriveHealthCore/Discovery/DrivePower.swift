/*
 * DrivePower.swift — best-effort drive power-state check via IOKit.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit

public enum DrivePower {
    /// Whether the device currently reports a reduced power state (e.g. a
    /// spun-down HDD). Reading registry properties never wakes the device,
    /// unlike issuing a SMART command.
    ///
    /// The power-managed node differs per transport (the block storage device
    /// itself, its driver, or the controller), so a few ancestors are checked
    /// too. Returns nil when no power state is readable — callers should then
    /// poll normally.
    public static func isLikelyAsleep(registryEntryID: UInt64) -> Bool? {
        var entry = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard entry != 0 else { return nil }

        for _ in 0..<4 {
            if let state = powerState(of: entry) {
                IOObjectRelease(entry)
                return state.current < state.max
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

    private static func powerState(of entry: io_registry_entry_t)
        -> (current: Int, max: Int)? {
        guard let value = IORegistryEntryCreateCFProperty(
            entry, "IOPowerManagement" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        guard let dict = value.takeRetainedValue() as? [String: Any],
              let current = dict["CurrentPowerState"] as? Int,
              let max = dict["MaxPowerState"] as? Int,
              max > 0
        else { return nil }
        return (current, max)
    }
}
