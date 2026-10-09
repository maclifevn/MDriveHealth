/*
 * DriveServices.swift — TRIM lookup and eject via bounded system commands.
 * MDriveHealth, GPL-3.0-or-later.
 */
import Foundation
import MDriveHealthCore

protocol SystemCommandRunning: Sendable {
    func run(_ command: ProcessCommand) async throws -> CommandOutput
}
struct SupervisedSystemCommands: SystemCommandRunning {
    func run(_ command: ProcessCommand) async throws -> CommandOutput { try await BoundedProcess.run(command) }
}

enum TrimStatusReader {
    /// nil means unavailable or unreported, never "TRIM disabled".
    static func trimSupport(bsdName: String, runner: any SystemCommandRunning = SupervisedSystemCommands()) async -> Bool? {
        do { return try await lookupSupport(bsdName: bsdName, runner: runner) }
        catch { return nil }
    }
    static func lookupSupport(bsdName: String, runner: any SystemCommandRunning = SupervisedSystemCommands()) async throws -> Bool? {
            let command = ProcessCommand("/usr/sbin/system_profiler", ["-json", "SPNVMeDataType", "SPSerialATADataType"], timeout: 15, scope: "trim-system-profiler")
            let output = try await runner.run(command)
            guard let root = try JSONSerialization.jsonObject(with: output.requireSuccess()) as? [String: Any] else { return nil }
            for key in ["SPNVMeDataType", "SPSerialATADataType"] {
                for controller in root[key] as? [[String: Any]] ?? [] {
                    for item in controller["_items"] as? [[String: Any]] ?? [] {
                        guard item["bsd_name"] as? String == bsdName else { continue }
                        for trimKey in ["spnvme_trim_support", "spsata_trim_support"] {
                            if let value = item[trimKey] as? String {
                                if value == "Yes" { return true }
                                if value == "No" { return false }
                                return nil
                            }
                        }
                    }
                }
            }
            return nil
    }
}

enum EjectOutcome: Sendable {
    case ejected, blocked([String]), failed(String)
    case stalled(String, PendingChild)
}
private enum EjectLookupError: Error, LocalizedError {
    case tooManyBlockers
    case commandDiagnostic(String)
    var errorDescription: String? {
        switch self {
        case .tooManyBlockers:
            return String(localized: "eject.tooManyBlockers", defaultValue: "Danh sách tiến trình giữ file vượt giới hạn, không thể liệt kê đầy đủ.")
        case .commandDiagnostic(let message): return message
        }
    }
}
enum EjectService {
    static func eject(drive: DriveInfo, volumes: [VolumeUsage], force: Bool,
                      runner: any SystemCommandRunning = SupervisedSystemCommands()) async -> EjectOutcome {
        guard drive.bsdName.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else { return .failed("Invalid whole-disk BSD name") }
        var arguments = ["unmountDisk"]
        if force { arguments.append("force") }
        arguments.append("/dev/\(drive.bsdName)")
        var command = ProcessCommand("/usr/sbin/diskutil", arguments, timeout: 30, scope: "eject:" + drive.bsdName)
        command.stdoutLimit = 1_048_576
        do {
            let result = try await runner.run(command)
            if result.termination.succeeded { return .ejected }
            var diagnostic = String(decoding: (result.stdout + result.stderr).prefix(4096), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !force {
                do {
                    let blockers = try await blockingProcesses(volumes: volumes, runner: runner)
                    if !blockers.isEmpty { return .blocked(blockers) }
                } catch {
                    if let error = error as? CommandError, let pending = error.pendingChild { return .stalled(error.localizedDescription, pending) }
                    diagnostic += "\n" + String(localized: "eject.blockerLookupFailed", defaultValue: "Không xác định được tiến trình giữ file: \(error.localizedDescription)")
                }
            }
            return .failed(diagnostic.isEmpty ? "diskutil: \(result.termination)" : diagnostic)
        } catch {
            if let error = error as? CommandError, let pending = error.pendingChild { return .stalled(error.localizedDescription, pending) }
            return .failed(error.localizedDescription)
        }
    }
    private static func blockingProcesses(volumes: [VolumeUsage], runner: any SystemCommandRunning) async throws -> [String] {
        var names: Set<String> = []
        for volume in volumes where volume.mountPoint.hasPrefix("/Volumes/") {
            var command = ProcessCommand("/usr/sbin/lsof", ["-Fc", "+f", "--", volume.mountPoint], timeout: 10, scope: "eject-blockers:" + volume.bsdName)
            command.stdoutLimit = 1_048_576
            let result = try await runner.run(command)
            // lsof uses 1 for a successful search with no matches. stderr or a
            // different status still means unknown, not "no process holds files".
            if result.termination == .exited(1) && result.stdout.isEmpty && result.stderr.isEmpty { continue }
            let data = try result.requireSuccess()
            guard result.stderr.isEmpty else {
                throw EjectLookupError.commandDiagnostic(String(decoding: result.stderr.prefix(2048), as: UTF8.self))
            }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("c") {
                names.insert(String(line.dropFirst()))
                guard names.count <= 128 else { throw EjectLookupError.tooManyBlockers }
            }
        }
        return names.sorted()
    }
}
