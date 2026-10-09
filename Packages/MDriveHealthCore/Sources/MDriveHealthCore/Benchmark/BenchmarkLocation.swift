/*
 * BenchmarkLocation.swift — where the test file lives and pre-run checks.
 * The URL/free-space logic is pure so it can be unit-tested without touching
 * a real volume; preflight() adds the live filesystem checks.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation

public enum BenchmarkLocation {
    /// Legacy name, retained for identifying old leftovers. Never reclaimed
    /// automatically: previous versions did not record ownership.
    public static let testFileName = ".com.maclife.mdrivehealth.speedtest.tmp"
    /// FAT32 (msdos) hard limit: 4 GiB − 1.
    public static let fat32MaxFileSize: UInt64 = (1 << 32) - 1

    static func writeDirectory(for volume: VolumeUsage) -> URL {
        volume.mountPoint == "/" ? FileManager.default.temporaryDirectory
            : URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
    }

    /// Legacy location only. New runs use an exclusive DiskTestWorkspace.
    public static func testFileURL(for volume: VolumeUsage) -> URL {
        if volume.mountPoint == "/" {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent(testFileName)
        }
        return URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
            .appendingPathComponent(testFileName)
    }

    /// Pure free-space gate.
    public static func validateFreeSpace(availableBytes: UInt64,
                                         config: BenchmarkConfig) throws {
        if availableBytes < config.requiredFreeBytes {
            throw BenchmarkError.insufficientFreeSpace(
                requiredBytes: config.requiredFreeBytes, availableBytes: availableBytes)
        }
    }

    /// Runtime preflight: rejects read-only volumes and filesystem size caps,
    /// then re-reads live free space (never trusts a stale cached snapshot at
    /// run time) and validates it. Returns the resolved test-file URL.
    public static func preflight(volume: VolumeUsage,
                                 config: BenchmarkConfig) throws -> URL {
        try config.validate()
        let workspace = try DiskTestWorkspace.open(volume: volume)
        return try workspace.withCleanup {
            try validate(workspace: workspace, config: config)
            return testFileURL(for: volume)
        }
    }

    static func validate(workspace: DiskTestWorkspace, config: BenchmarkConfig) throws {
        if try workspace.filesystemType() == "msdos", config.fileSizeBytes > fat32MaxFileSize {
            throw BenchmarkError.fileTooLargeForFilesystem(maximumBytes: fat32MaxFileSize)
        }
        try validateFreeSpace(availableBytes: workspace.freeBytes(), config: config)
    }
}
