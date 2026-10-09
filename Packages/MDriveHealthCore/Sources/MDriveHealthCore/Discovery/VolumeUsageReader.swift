/*
 * VolumeUsageReader.swift — mounted-volume capacity per physical drive.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import IOKit

/// One mounted volume that lives on a physical drive.
public struct VolumeUsage: Sendable, Codable, Hashable, Identifiable {
    /// BSD name of the mounted filesystem device (e.g. "disk3s1").
    public let bsdName: String
    /// User-visible volume name (e.g. "Macintosh HD").
    public let name: String
    public let mountPoint: String
    /// Filesystem capacity. For APFS this is the container size, shared by
    /// every volume in the same container.
    public let totalBytes: UInt64
    public let availableBytes: UInt64
    /// Volumes with the same key share `totalBytes`/`availableBytes`
    /// (APFS volumes of one container) — count each group once in totals.
    public let sharedCapacityKey: String
    public let mountIdentity: MountedFilesystemIdentity?
    public let writeIdentity: MountedFilesystemIdentity?
    /// Nil in older history records; such records cannot authorize writes or
    /// prove absence of a workspace until fresh discovery captures the parent.
    public let writeDirectoryIdentity: WorkspaceDirectoryIdentity?

    public init(bsdName: String, name: String, mountPoint: String, totalBytes: UInt64,
                availableBytes: UInt64, sharedCapacityKey: String,
                mountIdentity: MountedFilesystemIdentity? = nil,
                writeIdentity: MountedFilesystemIdentity? = nil,
                writeDirectoryIdentity: WorkspaceDirectoryIdentity? = nil) {
        self.bsdName = bsdName; self.name = name; self.mountPoint = mountPoint
        self.totalBytes = totalBytes; self.availableBytes = availableBytes
        self.sharedCapacityKey = sharedCapacityKey
        self.mountIdentity = mountIdentity; self.writeIdentity = writeIdentity
        self.writeDirectoryIdentity = writeDirectoryIdentity
    }

    public var id: String { bsdName }
    public var sharesCapacity: Bool { sharedCapacityKey != bsdName }
    public var usedBytes: UInt64 {
        totalBytes > availableBytes ? totalBytes - availableBytes : 0
    }
}

/// Volumes that share one pool of capacity (an APFS container, or a single
/// plain-filesystem partition). The group's numbers come from any member —
/// they are identical within the group by construction.
public struct VolumeCapacityGroup: Sendable, Hashable, Identifiable {
    public let key: String
    public let volumes: [VolumeUsage]

    public var id: String { key }
    public var totalBytes: UInt64 { volumes.first?.totalBytes ?? 0 }
    public var usedBytes: UInt64 { volumes.first?.usedBytes ?? 0 }
    public var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
    /// "Macintosh HD, DATA"
    public var displayName: String {
        volumes.map(\.name).joined(separator: ", ")
    }
}

public enum VolumeUsageReader {
    /// Mounted volumes residing on the given drive (by IOKit registry entry
    /// of its IOBlockStorageDevice). Covers APFS synthesized volumes: their
    /// IOMedia nodes are descendants of the physical media in the IOService
    /// plane, via AppleAPFSContainerScheme on the physical store partition.
    public static func volumes(forDriveRegistryEntryID registryEntryID: UInt64)
        -> [VolumeUsage] {
        volumes(forDriveRegistryEntryID: registryEntryID,
                mounts: mountedFilesystems())
    }

    /// Batch variant: reads the mount table (and volume capacities) once for
    /// the whole fleet instead of once per drive per refresh.
    public static func volumes(forDrives drives: [DriveInfo]) -> [UInt64: [VolumeUsage]] {
        let mounts = mountedFilesystems()
        var byDrive: [UInt64: [VolumeUsage]] = [:]
        for drive in drives {
            byDrive[drive.id] = volumes(forDriveRegistryEntryID: drive.registryEntryID,
                                        mounts: mounts)
        }
        return byDrive
    }

    private static func volumes(forDriveRegistryEntryID registryEntryID: UInt64,
                                mounts: [(bsdName: String, mountPoint: String, fileSystemType: String)])
        -> [VolumeUsage] {
        let deviceNames = descendantMediaBSDNames(of: registryEntryID)
        guard !deviceNames.isEmpty else { return [] }

        var volumes: [VolumeUsage] = []
        for mount in mounts {
            // Snapshot mounts ("disk3s3s1") have no IOMedia node of their
            // own; peel partition suffixes until a known device matches.
            guard belongsToDrive(mount.bsdName, deviceNames: deviceNames) else {
                continue
            }
            // Keep user-facing mounts: the boot volume and /Volumes/*.
            // /System/Volumes/* (Data, Preboot, VM...) shares the boot
            // container and would double-list the same capacity.
            guard mount.mountPoint == "/"
                || mount.mountPoint.hasPrefix("/Volumes/") else { continue }

            let url = URL(fileURLWithPath: mount.mountPoint)
            let values = try? url.resourceValues(forKeys: [
                .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
            ])
            guard let total = values?.volumeTotalCapacity, total > 0 else { continue }
            let important = values?.volumeAvailableCapacityForImportantUsage
            let plain = values?.volumeAvailableCapacity
            let available = (important.map(Int.init) ?? plain) ?? 0

            volumes.append(VolumeUsage(
                bsdName: mount.bsdName,
                name: values?.volumeName
                    ?? URL(fileURLWithPath: mount.mountPoint).lastPathComponent,
                mountPoint: mount.mountPoint,
                totalBytes: UInt64(total),
                availableBytes: UInt64(max(0, available)),
                sharedCapacityKey: sharedCapacityKey(
                    bsdName: mount.bsdName, fileSystemType: mount.fileSystemType),
                mountIdentity: MountedFilesystemIdentity.capture(at: url),
                writeIdentity: MountedFilesystemIdentity.capture(at:
                    mount.mountPoint == "/" ? FileManager.default.temporaryDirectory : url),
                writeDirectoryIdentity: WorkspaceDirectoryIdentity.capture(at:
                    mount.mountPoint == "/" ? FileManager.default.temporaryDirectory : url)))
        }
        return volumes.sorted { $0.bsdName.localizedStandardCompare($1.bsdName) == .orderedAscending }
    }

    /// Groups volumes that share capacity, preserving first-seen order.
    /// The single source of the "count each APFS container once" rule —
    /// used by the app UI, the text report, the CLI, and `summary(of:)`.
    public static func capacityGroups(_ volumes: [VolumeUsage]) -> [VolumeCapacityGroup] {
        var order: [String] = []
        var byKey: [String: [VolumeUsage]] = [:]
        for volume in volumes {
            if byKey[volume.sharedCapacityKey] == nil {
                order.append(volume.sharedCapacityKey)
            }
            byKey[volume.sharedCapacityKey, default: []].append(volume)
        }
        return order.map { VolumeCapacityGroup(key: $0, volumes: byKey[$0] ?? []) }
    }

    /// Drive-level capacity: each shared-capacity group counts once.
    public static func summary(of volumes: [VolumeUsage])
        -> (totalBytes: UInt64, usedBytes: UInt64)? {
        let groups = capacityGroups(volumes)
        guard !groups.isEmpty else { return nil }
        return (groups.reduce(0) { $0 &+ $1.totalBytes },
                groups.reduce(0) { $0 &+ $1.usedBytes })
    }

    // MARK: - Internals

    /// Capacity-sharing unit for a mounted filesystem: APFS volumes share
    /// their synthesized container ("disk3s1" → "disk3"); every other
    /// filesystem owns exactly its partition ("disk5s2" stays "disk5s2", so
    /// two exFAT partitions on one disk are not collapsed into one group).
    static func sharedCapacityKey(bsdName: String, fileSystemType: String) -> String {
        fileSystemType == "apfs" ? containerKey(for: bsdName) : bsdName
    }

    /// "disk3s1" / "disk3s3s1" → "disk3".
    static func containerKey(for bsdName: String) -> String {
        guard bsdName.hasPrefix("disk") else { return bsdName }
        let digits = bsdName.dropFirst(4).prefix(while: \.isNumber)
        return digits.isEmpty ? bsdName : "disk\(digits)"
    }

    static func belongsToDrive(_ bsdName: String, deviceNames: Set<String>) -> Bool {
        var candidate = Substring(bsdName)
        while !candidate.isEmpty {
            if deviceNames.contains(String(candidate)) { return true }
            // Strip one trailing "s<digits>" partition/snapshot suffix.
            guard let cut = candidate.lastIndex(of: "s"),
                  cut > candidate.startIndex,
                  candidate[candidate.index(after: cut)...].allSatisfy(\.isNumber),
                  !candidate[candidate.index(after: cut)...].isEmpty
            else { return false }
            candidate = candidate[..<cut]
        }
        return false
    }

    private static func descendantMediaBSDNames(of registryEntryID: UInt64) -> Set<String> {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(
            service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively),
            &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var names: Set<String> = []
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            guard IOObjectConformsTo(child, "IOMedia") != 0 else { continue }
            if let value = IORegistryEntryCreateCFProperty(
                child, "BSD Name" as CFString, kCFAllocatorDefault, 0),
               let name = value.takeRetainedValue() as? String {
                names.insert(name)
            }
        }
        return names
    }

    private static func mountedFilesystems()
        -> [(bsdName: String, mountPoint: String, fileSystemType: String)] {
        var pointer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&pointer, MNT_NOWAIT)
        guard count > 0, let list = pointer else { return [] }

        var mounts: [(String, String, String)] = []
        for index in 0..<Int(count) {
            let stat = list[index]
            let device = fixedString(stat.f_mntfromname)
            guard device.hasPrefix("/dev/disk") else { continue }
            mounts.append((String(device.dropFirst("/dev/".count)),
                           fixedString(stat.f_mntonname),
                           fixedString(stat.f_fstypename)))
        }
        return mounts
    }
}
