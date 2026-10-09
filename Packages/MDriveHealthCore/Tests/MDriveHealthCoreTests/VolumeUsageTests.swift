/*
 * VolumeUsageTests.swift — pure helpers of VolumeUsageReader.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import XCTest
@testable import MDriveHealthCore

final class VolumeUsageTests: XCTestCase {
    func testContainerKey() {
        XCTAssertEqual(VolumeUsageReader.containerKey(for: "disk3s1"), "disk3")
        XCTAssertEqual(VolumeUsageReader.containerKey(for: "disk3s3s1"), "disk3")
        XCTAssertEqual(VolumeUsageReader.containerKey(for: "disk12"), "disk12")
        XCTAssertEqual(VolumeUsageReader.containerKey(for: "weird"), "weird")
    }

    func testSharedCapacityKeyGroupsOnlyAPFSByContainer() {
        // APFS volumes share their container's capacity.
        XCTAssertEqual(VolumeUsageReader.sharedCapacityKey(
            bsdName: "disk3s1", fileSystemType: "apfs"), "disk3")
        // Plain filesystems own exactly their partition: two exFAT
        // partitions on one disk must NOT collapse into one group.
        XCTAssertEqual(VolumeUsageReader.sharedCapacityKey(
            bsdName: "disk5s2", fileSystemType: "exfat"), "disk5s2")
        XCTAssertEqual(VolumeUsageReader.sharedCapacityKey(
            bsdName: "disk5s3", fileSystemType: "exfat"), "disk5s3")
        XCTAssertEqual(VolumeUsageReader.sharedCapacityKey(
            bsdName: "disk2s2", fileSystemType: "hfs"), "disk2s2")
    }

    func testBelongsToDriveMatchesDescendantsAndSnapshots() {
        let names: Set<String> = ["disk0", "disk0s2", "disk3", "disk3s1", "disk3s3"]
        XCTAssertTrue(VolumeUsageReader.belongsToDrive("disk3s1", deviceNames: names))
        // Snapshot mounts have no IOMedia node; suffix-stripping must reach
        // the volume node ("disk3s3").
        XCTAssertTrue(VolumeUsageReader.belongsToDrive("disk3s3s1", deviceNames: names))
        XCTAssertFalse(VolumeUsageReader.belongsToDrive("disk4s1", deviceNames: names))
        XCTAssertFalse(VolumeUsageReader.belongsToDrive("disk30s1", deviceNames: names))
    }

    func testSummaryCountsSharedContainersOnce() {
        let apfs = { (bsd: String, name: String) in
            VolumeUsage(bsdName: bsd, name: name, mountPoint: "/Volumes/\(name)",
                        totalBytes: 1_000, availableBytes: 400,
                        sharedCapacityKey: VolumeUsageReader.sharedCapacityKey(
                            bsdName: bsd, fileSystemType: "apfs"))
        }
        let volumes = [
            apfs("disk3s1", "Macintosh HD"),
            apfs("disk3s5", "DATA"),      // same APFS container as above
            apfs("disk8s2", "Backup"),    // separate container
        ]
        let summary = VolumeUsageReader.summary(of: volumes)
        XCTAssertEqual(summary?.totalBytes, 2_000)
        XCTAssertEqual(summary?.usedBytes, 1_200)
        XCTAssertNil(VolumeUsageReader.summary(of: []))
    }

    func testCapacityGroupsPreserveOrderAndMembers() {
        let volume = { (bsd: String, name: String, fs: String, total: UInt64) in
            VolumeUsage(bsdName: bsd, name: name, mountPoint: "/Volumes/\(name)",
                        totalBytes: total, availableBytes: total / 2,
                        sharedCapacityKey: VolumeUsageReader.sharedCapacityKey(
                            bsdName: bsd, fileSystemType: fs))
        }
        let groups = VolumeUsageReader.capacityGroups([
            volume("disk3s1", "Macintosh HD", "apfs", 1_000),
            volume("disk3s5", "DATA", "apfs", 1_000),
            volume("disk5s2", "GAME", "exfat", 500),
            volume("disk5s3", "FILM", "exfat", 700),
        ])
        XCTAssertEqual(groups.map(\.key), ["disk3", "disk5s2", "disk5s3"])
        XCTAssertEqual(groups[0].displayName, "Macintosh HD, DATA")
        XCTAssertEqual(groups[0].totalBytes, 1_000)
        // exFAT partitions stay separate — 500 + 700, not collapsed to 500.
        XCTAssertEqual(groups[1].totalBytes, 500)
        XCTAssertEqual(groups[2].totalBytes, 700)
    }
}

final class USBBridgeReaderTests: XCTestCase {
    func testSpeedEnumMapsToMbps() {
        XCTAssertEqual(USBBridgeReader.speedMbps(fromUSBSpeedValue: 3), 480)
        XCTAssertEqual(USBBridgeReader.speedMbps(fromUSBSpeedValue: 4), 5_000)
        XCTAssertEqual(USBBridgeReader.speedMbps(fromUSBSpeedValue: 5), 10_000)
        XCTAssertEqual(USBBridgeReader.speedMbps(fromUSBSpeedValue: 6), 20_000)
        XCTAssertNil(USBBridgeReader.speedMbps(fromUSBSpeedValue: 0))
        XCTAssertNil(USBBridgeReader.speedMbps(fromUSBSpeedValue: 99))
    }

    func testInternalDriveHasNoBridge() throws {
        // The internal Apple SSD must not report a USB bridge.
        let drives = (try? DriveEnumerator().enumerate()) ?? []
        guard let internalDrive = drives.first(where: { $0.isInternal }) else {
            throw XCTSkip("no internal drive found")
        }
        XCTAssertNil(USBBridgeReader.bridgeInfo(
            forDriveRegistryEntryID: internalDrive.registryEntryID))
    }
}
