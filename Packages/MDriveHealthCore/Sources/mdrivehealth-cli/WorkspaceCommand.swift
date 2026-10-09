/* Explicit inspection/cleanup of owned leftovers. GPL-3.0-or-later. */
import Foundation
import MDriveHealthCore

func runWorkspaceCommand(arguments: [String]) {
    guard let target = arguments.first, !target.hasPrefix("-") else { workspaceUsageError() }
    var cleanupName: String?, proof: String?, json = false
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--json": guard !json else { workspaceUsageError() }; json = true
        case "--cleanup":
            index += 1
            guard index < arguments.count, cleanupName == nil else { workspaceUsageError() }
            cleanupName = arguments[index]
        case "--proof":
            index += 1
            guard index < arguments.count, proof == nil else { workspaceUsageError() }
            proof = arguments[index]
        default: workspaceUsageError()
        }
        index += 1
    }
    guard (cleanupName == nil) == (proof == nil) else { workspaceUsageError() }
    do {
        // Require an exact mounted volume, never the first volume of a disk.
        var matches: [(DriveInfo, VolumeUsage)] = []
        for drive in try cliDrives() {
            for volume in try cliVolumes(drive) where volume.mountPoint == target || volume.bsdName == target {
                matches.append((drive, volume))
            }
        }
        guard matches.count == 1, let (drive, volume) = matches.first else {
            throw WorkspaceRecoveryError.unsafe("Specify exactly one mounted volume path or volume BSD name")
        }
        guard case .workspaces(let scan) = try cliHardware.performBlocking(.workspaces(drive, volume: volume)) else { throw HardwareWorkerError.protocolViolation }
        if let cleanupName, let proof {
            guard let entry = scan.leftovers.first(where: { $0.name == cleanupName }), entry.status == .recoverable,
                  entry.proof == proof else { throw WorkspaceRecoveryError.changed }
            try DriveCommandLock.withLease(registryEntryID: drive.id) { lease in
                try cliHardware.cleanupWorkspaceBlocking(drive, volume: volume, leftover: entry, lease: lease)
            }
            if json { print(String(decoding: try JSONEncoder().encode(["cleaned": cleanupName]), as: UTF8.self)) }
            else { print("Đã dọn workspace có ownership khớp: \(String(reflecting: entry.path))") }
        } else if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(scan), as: UTF8.self))
        } else {
            for entry in scan.leftovers {
                print(String(reflecting: entry.path))
                if entry.status == .recoverable {
                    print("  Có ownership hợp lệ · \(formatBytes(entry.bytes ?? 0)) · \(entry.fileCount ?? 0) file đã đăng ký")
                    print("  proof: \(entry.proof ?? "")")
                } else { print("  Chưa xác minh; giữ nguyên: \(entry.diagnostic ?? "")") }
            }
            if scan.leftovers.isEmpty && scan.complete { print("Không phát hiện workspace còn sót tại vị trí ghi hiện tại.") }
            if let diagnostic = scan.diagnostic { FileHandle.standardError.write(Data((diagnostic + "\n").utf8)) }
        }
        if !scan.complete { exit(3) }
    } catch {
        FileHandle.standardError.write(Data("Lỗi: \(error.localizedDescription)\n".utf8)); exit(1)
    }
}
private func workspaceUsageError() -> Never {
    FileHandle.standardError.write(Data("Dùng: mdrivehealth-cli workspaces <volume-path|volume-BSD> [--json] [--cleanup <workspace-name> --proof <hash-từ-lần-quét>]\n".utf8))
    exit(2)
}
