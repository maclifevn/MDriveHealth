/* Read-only packaged helper smoke. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import MDriveHealthCore

@main struct HardwareSmoke {
    static func main() async throws {
        let started = Date(), client = HardwareWorkerClient(executable: CommandLine.arguments[1])
        var summary: [String: Any] = ["mutatingHardwareCommands": 0]
        guard case .drives(let drives) = try await client.perform(.enumerate) else { throw HardwareWorkerError.protocolViolation }
        summary["fleetCount"] = drives.count; summary["bundledDriveDatabaseLoaded"] = true
        if let drive = drives.first(where: { !$0.isVirtual && $0.smartInterface == .nvme }) {
            guard case .inspection(let result) = try await client.perform(.inspect(drive, avoidWakingIdle: true)), let reading = result.reading else { throw HardwareWorkerError.protocolViolation }
            summary["nvmeReadingAvailable"] = true; summary["mountedVolumes"] = result.volumes.count
            summary["healthCoverage"] = reading.evaluateHealth().coverage.rawValue
            if let volume = result.volumes.first(where: { $0.mountPoint == "/" }) {
                guard let parent = volume.writeDirectoryIdentity, parent.isValid,
                      case .workspaces(let scan) = try await client.perform(.workspaces(drive, volume: volume)) else { throw HardwareWorkerError.protocolViolation }
                try scan.validate(parentPath: DiskWorkspaceRecovery.writeDirectoryPath(for: volume), expectedParentIdentity: parent)
                summary["workspaceParentIdentityVerified"] = true
                summary["workspaceScanComplete"] = scan.complete
                summary["workspaceCandidates"] = scan.leftovers.count
                summary["workspaceCleanupCalls"] = 0
            }
            let lease = try DriveCommandLock.acquire(registryEntryID: drive.id)
            defer { lease.release() }
            _ = try await client.measurementStatus(drive, lease: lease)
            summary["delegatedLeaseValidated"] = true
        }
        if case .memory(let value) = try await client.perform(.memory) { summary["memoryAvailable"] = value != nil }
        if case .battery(let value) = try await client.perform(.battery) { summary["batteryPresent"] = value != nil }
        if case .sensors(let values) = try await client.perform(.sensors) { summary["sensorCount"] = values.count }
        summary["elapsedSeconds"] = Date().timeIntervalSince(started)
        let bytes = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
        print(String(decoding: bytes, as: UTF8.self))
    }
}
