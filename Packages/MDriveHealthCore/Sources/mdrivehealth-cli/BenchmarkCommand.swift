/*
 * BenchmarkCommand.swift — `mdrivehealth-cli benchmark` subcommand.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var tripped = false
    func trip() { lock.lock(); tripped = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return tripped }
}

func runBenchmarkCommand(arguments: [String]) {
    guard let target = arguments.first, !target.hasPrefix("-") else {
        FileHandle.standardError.write(Data(
            "Cần chỉ định volume: mdrivehealth-cli benchmark </Volumes/X | diskNsM>\n".utf8))
        exit(2)
    }

    var config = BenchmarkConfig()
    var record = true
    var index = 1
    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--size":
            index += 1
            guard index < arguments.count, let size = parseSize(arguments[index]) else {
                FileHandle.standardError.write(Data("--size cần 512m|1g|2g|5g\n".utf8)); exit(2)
            }
            config.fileSizeBytes = size
        case "--no-random":
            config.includeRandomPhases = false
        case "--no-record":
            record = false
        case "--depth":
            index += 1
            guard index < arguments.count, let depth = Int(arguments[index]),
                  (1...16).contains(depth) else {
                FileHandle.standardError.write(Data("--depth cần 1-16\n".utf8)); exit(2)
            }
            config.queueDepth = depth
        default:
            FileHandle.standardError.write(Data("Tham số lạ: \(arg)\n".utf8)); exit(2)
        }
        index += 1
    }

    guard let (volume, drive, identity) = resolveVolume(target: target) else {
        FileHandle.standardError.write(Data("Không tìm thấy volume \"\(target)\".\n".utf8))
        exit(1)
    }

    print("Đo tốc độ: \(volume.name) (\(volume.bsdName)) tại \(volume.mountPoint)")
    print("File \(formatBytes(config.fileSizeBytes)), block \(formatBytes(UInt64(config.sequentialBlockBytes)))"
          + (config.includeRandomPhases ? " + Random 4K" : "") + "\n")

    // Ctrl-C, SIGTERM, and a closed terminal trip the flag on a background
    // queue so cancellation is seen even while the main thread is blocked in
    // the benchmark loop; the engine's defer then deletes the (multi-GB)
    // test file. SIGKILL cannot run cleanup; the ownership manifest supports
    // explicit inspection/recovery on the next invocation.
    let cancel = CancelFlag()
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { cancel.trip() }
        source.resume()
        signalSources.append(source)
    }
    _ = signalSources   // kept alive for the duration of the run

    do {
        let (result, captured) = try DriveCommandLock.withLease(registryEntryID: drive.id) { lease in
            try cliPrepareMeasurement(drive, lease: lease)
            let job = try cliMeasurements.prepareJobBlocking(.init(drive: drive, driveKey: identity.key, volume: volume,
                operation: .benchmark(config), origin: .init(drive: drive, identity: identity), historyPolicy: record ? .archive : .omit))
            let result = try cliMeasurements.benchmarkBlocking(drive: drive,
            volume: volume, config: config, id: job.intent.id, lease: lease, job: job,
            isCancelled: { cancel.isSet },
            progress: { p in
                let mbps = String(format: "%7.1f", p.instantaneousBytesPerSecond / 1e6)
                print("\r\(phaseLabel(p.phase))  \(Int(p.fractionCompleted * 100))%  \(mbps) MB/s      ",
                      terminator: "")
                fflush(stdout)
            })
            return (result, try job.cachedRecord() ?? job.record())
        }
        print("\r\u{1B}[K", terminator: "")   // clear the progress line

        printResult(result)
        if !persistCLI(captured) { exit(1) }
    } catch let error as MeasurementWorkerError {
        switch error {
        case .resultNotPersisted(let recovered, _), .resultNotDelivered(let recovered, _):
            if case .benchmark(let result) = recovered.terminal?.outcome {
                printResult(result); _ = persistCLI(recovered)
            }
        default: break
        }
        FileHandle.standardError.write(Data("\nLỗi worker/journal: \(error.localizedDescription)\n".utf8)); exit(1)
    } catch let error as BenchmarkError where error == .cancelled {
        print("\nĐã huỷ.")
        exit(130)
    } catch let error as CommandError where error.reason == .cancelled {
        FileHandle.standardError.write(Data("\nĐã hủy; trạng thái cleanup chưa xác nhận: \(error.localizedDescription)\n".utf8)); exit(130)
    } catch {
        FileHandle.standardError.write(Data("\nLỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - Capacity verification

func runVerifyCapacityCommand(arguments: [String]) {
    guard let target = arguments.first, !target.hasPrefix("-") else {
        FileHandle.standardError.write(Data(
            "Cần chỉ định volume: mdrivehealth-cli verify-capacity </Volumes/X | diskNsM> --acknowledge-data-risk [--acknowledge-shared-capacity-risk] [--max 512m|1g|2g|5g]\n".utf8))
        exit(2)
    }
    var config = CapacityVerifyConfig()
    var index = 1
    while index < arguments.count {
        switch arguments[index] {
        case "--acknowledge-data-risk":
            config.dataRiskAcknowledged = true
        case "--acknowledge-shared-capacity-risk":
            config.sharedCapacityRiskAcknowledged = true
        case "--max":
            index += 1
            guard index < arguments.count, let size = parseSize(arguments[index]) else {
                FileHandle.standardError.write(Data("--max cần 512m|1g|2g|5g\n".utf8)); exit(2)
            }
            config.maxBytes = size
        default:
            FileHandle.standardError.write(Data("Tham số lạ: \(arguments[index])\n".utf8)); exit(2)
        }
        index += 1
    }

    guard let (volume, drive, identity) = resolveVolume(target: target) else {
        FileHandle.standardError.write(Data("Không tìm thấy volume \"\(target)\".\n".utf8))
        exit(1)
    }

    guard volume.mountPoint != "/" else {
        FileHandle.standardError.write(Data((BenchmarkError.unsafeCapacityTarget.localizedDescription + "\n").utf8)); exit(2)
    }
    guard config.dataRiskAcknowledged, !volume.sharesCapacity || config.sharedCapacityRiskAcknowledged else {
        FileHandle.standardError.write(Data((BenchmarkError.capacityRiskNotAcknowledged.localizedDescription + "\nDùng --acknowledge-data-risk và, với APFS, --acknowledge-shared-capacity-risk.\n").utf8)); exit(2)
    }
    print("Kiểm tra dữ liệu:  \(volume.name) tại \(volume.mountPoint)")
    print("Chỉ bắt đầu trên volume đã sao lưu hoặc trống có thể xóa bỏ. Firmware khai khống có thể làm hỏng dữ liệu cũ. Ctrl-C để huỷ.\n")

    let cancel = CancelFlag()
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
        source.setEventHandler { cancel.trip() }
        source.resume()
        signalSources.append(source)
    }
    _ = signalSources

    do {
        let (result, captured) = try DriveCommandLock.withLease(registryEntryID: drive.id) { lease in
            try cliPrepareMeasurement(drive, lease: lease)
            let job = try cliMeasurements.prepareJobBlocking(.init(drive: drive, driveKey: identity.key, volume: volume,
                operation: .capacity(config), origin: .init(drive: drive, identity: identity)))
            let result = try cliMeasurements.capacityBlocking(drive: drive,
            volume: volume, config: config, id: job.intent.id, lease: lease, job: job,
            isCancelled: { cancel.isSet },
            progress: { p in
                let label = p.phase == .filling ? "Ghi " : "Đọc+so"
                print("\r\(label)  \(Int(p.fractionCompleted * 100))%  \(String(format: "%7.1f", p.instantaneousBytesPerSecond / 1e6)) MB/s      ",
                      terminator: "")
                fflush(stdout)
            })
            return (result, try job.cachedRecord() ?? job.record())
        }
        print("\r\u{1B}[K", terminator: "")
        print(result.summaryTitle)
        print(result.summaryDetail)
        print(String(format: "Tốc độ: ghi %.1f MB/s · đọc %.1f MB/s",
                     result.writeBytesPerSec / 1e6, result.readBytesPerSec / 1e6))
        if !persistCLI(captured) { exit(1) }
    } catch let error as MeasurementWorkerError {
        switch error {
        case .resultNotPersisted(let recovered, _), .resultNotDelivered(let recovered, _):
            if case .capacity(let result) = recovered.terminal?.outcome {
                print(result.summaryTitle); print(result.summaryDetail); _ = persistCLI(recovered)
            }
        default: break
        }
        FileHandle.standardError.write(Data("\nLỗi worker/journal: \(error.localizedDescription)\n".utf8)); exit(1)
    } catch let error as BenchmarkError where error == .cancelled {
        print("\nĐã huỷ — file test đã được xoá.")
        exit(130)
    } catch let error as CommandError where error.reason == .cancelled {
        FileHandle.standardError.write(Data("\nĐã hủy; trạng thái cleanup chưa xác nhận: \(error.localizedDescription)\n".utf8)); exit(130)
    } catch {
        FileHandle.standardError.write(Data("\nLỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

// MARK: - Helpers

private func persistCLI(_ record: MeasurementJobRecord) -> Bool {
    do {
        let journal = try MeasurementJournal(rootURL: MeasurementJournal.defaultRootURL())
        if record.intent.historyPolicy == .omit {
            try journal.discardOmitted(id: record.id, recordSHA256: record.recordSHA256)
            return true
        }
        let history = try HistoryStore(); defer { try? history.close() }
        let receipt = try history.recordMeasurement(record)
        print("\nĐã lưu kết quả vào lịch sử (UUID \(record.id.uuidString)).")
        do { try journal.discardCommitted(receipt) }
        catch { FileHandle.standardError.write(Data("Đã lưu lịch sử; journal còn giữ để phục hồi: \(error.localizedDescription)\n".utf8)) }
        return true
    } catch {
        FileHandle.standardError.write(Data("Không lưu/hoàn tất journal được; giữ phiên \(record.id.uuidString) để phục hồi: \(error.localizedDescription)\n".utf8))
        return false
    }
}

private func parseSize(_ raw: String) -> UInt64? {
    switch raw.lowercased() {
    case "512m", "512mb": return 1 << 29
    case "1g", "1gb": return 1 << 30
    case "2g", "2gb": return 1 << 31
    case "5g", "5gb": return 5 << 30
    default: return nil
    }
}

/// Matches `target` against every mounted volume of every drive: a
/// `/Volumes/...` mount point, a volume BSD name ("disk3s1"), or a whole-disk
/// BSD name ("disk3", using its first mounted volume).
private func resolveVolume(target: String) -> (VolumeUsage, DriveInfo, DriveIdentity)? {
    guard let drives = try? cliDrives() else { return nil }
    let identities = DriveIdentity.isolatedFleet(drives.map { ($0, DriveIdentity.resolve(for: $0)) })
    var firstVolumeOfDrive: (VolumeUsage, DriveInfo, DriveIdentity)?
    for drive in drives {
        guard let volumes = try? cliVolumes(drive) else { continue }
        for volume in volumes {
            if volume.mountPoint == target || volume.bsdName == target {
                return (volume, drive, identities[drive.id]!)
            }
        }
        if drive.bsdName == target, let first = volumes.first, firstVolumeOfDrive == nil {
            firstVolumeOfDrive = (first, drive, identities[drive.id]!)
        }
    }
    return firstVolumeOfDrive
}

private func phaseLabel(_ phase: BenchmarkPhase) -> String {
    switch phase {
    case .sequentialWrite: return "Ghi tuần tự  "
    case .sequentialRead:  return "Đọc tuần tự  "
    case .randomWrite:     return "Ghi random 4K"
    case .randomRead:      return "Đọc random 4K"
    }
}

private func mbps(_ bytesPerSec: Double) -> String {
    String(format: "%.1f MB/s", bytesPerSec / 1e6)
}

private func printResult(_ result: BenchmarkResult) {
    print("── KẾT QUẢ " + String(repeating: "─", count: 36))
    print("  Tuần tự  · Ghi:  \(mbps(result.sequentialWriteBytesPerSec))")
    print("  Tuần tự  · Đọc:  \(mbps(result.sequentialReadBytesPerSec))")
    if let rw = result.randomWriteBytesPerSec {
        print(String(format: "  Random4K · Ghi:  %@  (%.0f IOPS)", mbps(rw), result.randomWriteIOPS ?? 0))
    }
    if let rr = result.randomReadBytesPerSec {
        print(String(format: "  Random4K · Đọc:  %@  (%.0f IOPS)", mbps(rr), result.randomReadIOPS ?? 0))
    }
}
