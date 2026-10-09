/*
 * DriveEnumerator.swift — discovers physical drives via the IOKit registry.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit

public enum DriveEnumeratorError: Error, LocalizedError {
    case ioKit(kern_return_t, String)

    public var errorDescription: String? {
        switch self {
        case .ioKit(let code, let what):
            return "\(what) failed (kern_return \(code))"
        }
    }
}

public struct DriveEnumerator: Sendable {
    public init() {}

    /// Resolve exactly this attachment without walking unrelated devices.
    public func lookup(registryEntryID: UInt64) throws -> DriveInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOObjectConformsTo(service, "IOBlockStorageDevice") != 0 else { return nil }
        return Self.driveInfo(for: service)
    }

    /// Enumerates all IOBlockStorageDevice services that currently expose media.
    /// Includes virtual devices (disk images); callers filter via `isVirtual`.
    public func enumerate() throws -> [DriveInfo] {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator)
        guard kr == KERN_SUCCESS else {
            throw DriveEnumeratorError.ioKit(kr, "IOServiceGetMatchingServices")
        }
        defer { IOObjectRelease(iterator) }

        var drives: [DriveInfo] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let drive = Self.driveInfo(for: service) {
                drives.append(drive)
            }
        }
        return drives.sorted {
            $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending
        }
    }

    private static func driveInfo(for service: io_service_t) -> DriveInfo? {
        guard let props = registryProperties(of: service) else { return nil }

        let deviceChars = props["Device Characteristics"] as? [String: Any] ?? [:]
        let protocolChars = props["Protocol Characteristics"] as? [String: Any] ?? [:]

        // Drives without inserted media (e.g. empty card readers) have no
        // IOMedia child; they cannot be probed, so skip them.
        guard let media = wholeMedia(of: service) else { return nil }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)

        let smartKind: SMARTInterfaceKind
        if props["NVMe SMART Capable"] as? Bool == true {
            smartKind = .nvme
        } else if props["SMART Capable"] as? Bool == true {
            smartKind = .ata
        } else {
            smartKind = .unsupported
        }

        let model = (deviceChars["Product Name"] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? "Unknown"
        let serial = (deviceChars["Serial Number"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let firmware = (deviceChars["Product Revision Level"] as? String)?
            .trimmingCharacters(in: .whitespaces)
        let mediumType = deviceChars["Medium Type"] as? String

        return DriveInfo(
            registryEntryID: entryID,
            bsdName: media.bsdName,
            model: model,
            serialNumber: serial?.isEmpty == true ? nil : serial,
            mediaUUID: media.uuid,
            firmwareRevision: firmware?.isEmpty == true ? nil : firmware,
            sizeBytes: media.sizeBytes,
            interconnect: protocolChars["Physical Interconnect"] as? String ?? "Unknown",
            location: protocolChars["Physical Interconnect Location"] as? String ?? "Unknown",
            isSolidState: mediumType == "Solid State",
            smartInterface: smartKind
        )
    }

    private static func registryProperties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }

    /// Finds the whole-disk IOMedia child (e.g. disk0) of a block storage device.
    private static func wholeMedia(of service: io_service_t)
        -> (bsdName: String, sizeBytes: UInt64, uuid: String?)? {
        var childIterator: io_iterator_t = 0
        let kr = IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
            &childIterator)
        guard kr == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(childIterator) }

        while true {
            let child = IOIteratorNext(childIterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }

            guard IOObjectConformsTo(child, "IOMedia") != 0,
                  let props = registryProperties(of: child),
                  props["Whole"] as? Bool == true,
                  let bsdName = props["BSD Name"] as? String
            else { continue }

            let size = (props["Size"] as? UInt64)
                ?? (props["Size"] as? NSNumber)?.uint64Value ?? 0
            let uuid = (props["UUID"] as? String)?.trimmingCharacters(in: .whitespaces)
            return (bsdName, size, uuid?.isEmpty == true ? nil : uuid)
        }
        return nil
    }
}
