/*
 * main.swift — mdrivehealth-cli: terminal SMART reporter (debug/verification).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import MDriveHealthCore

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--hardware-worker" { exit(DriveHardwareWorker.runStandardIO()) }
if arguments.first == "--measurement-worker" { exit(MeasurementWorker.runStandardIO()) }
let cliHardware = HardwareWorkerClient(executable: Bundle.main.executableURL?.path ?? CommandLine.arguments[0], arguments: ["--hardware-worker"])
let cliMeasurements = MeasurementWorkerClient(executable: Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
func cliDrives() throws -> [DriveInfo] {
    guard case .drives(let values) = try cliHardware.performBlocking(.enumerate) else { throw HardwareWorkerError.protocolViolation }; return values
}
func cliVolumes(_ drive: DriveInfo) throws -> [VolumeUsage] {
    guard case .volumes(let values) = try cliHardware.performBlocking(.volumes(drive)) else { throw HardwareWorkerError.protocolViolation }; return values
}
func cliReading(_ drive: DriveInfo) throws -> DriveReading {
    guard case .inspection(let value) = try cliHardware.performBlocking(.inspect(drive, avoidWakingIdle: false)), let reading = value.reading else { throw HardwareWorkerError.protocolViolation }; return reading
}
func cliPrepareMeasurement(_ drive: DriveInfo, lease: DriveCommandLock.Lease) throws {
    let value = try cliHardware.measurementStatusBlocking(drive, lease: lease)
    if drive.smartInterface == .ata {
        guard case .inspection(let inspection) = value, let status = inspection.reading?.ataSelfTest else { throw HardwareWorkerError.selfTestUnavailable }
        guard !status.inProgress else { throw HardwareWorkerError.selfTestRunning }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: Int64(clamping: bytes))
}

func printUsage() {
    print("""
    mdrivehealth-cli — MDriveHealth terminal reporter

    Usage:
      mdrivehealth-cli list            Liệt kê tất cả ổ đĩa
      mdrivehealth-cli smart [diskN]   Báo cáo SMART chi tiết (mặc định: mọi ổ hỗ trợ)
      mdrivehealth-cli benchmark <vol> [--size 512m|1g|2g|5g] [--no-random] [--no-record]
                                       Đo tốc độ (vol = /Volumes/X hoặc diskNsM)
      mdrivehealth-cli verify-capacity <vol> --acknowledge-data-risk [--acknowledge-shared-capacity-risk] [--max 1g|2g|5g]
                                       Kiểm tra dữ liệu đã ghi; không chứng nhận toàn bộ dung lượng
      mdrivehealth-cli workspaces <vol> [--json]
                                       Liệt kê file test còn sót và ownership; không tự xóa
      mdrivehealth-cli workspaces <vol> --cleanup <workspace-name> --proof <hash>
                                       Dọn một workspace đã được kiểm chứng từ lần quét trước
      mdrivehealth-cli help
    """)
}

func listDrives(_ drives: [DriveInfo]) {
    print("Phát hiện \(drives.count) thiết bị lưu trữ:\n")
    for drive in drives {
        let kind = drive.isVirtual ? "Virtual"
                 : drive.isSolidState ? "SSD" : "HDD"
        let smart: String
        switch drive.smartInterface {
        case .nvme: smart = "SMART: NVMe"
        case .ata: smart = "SMART: ATA"
        case .unsupported: smart = drive.isVirtual ? "—" : "SMART: không khả dụng"
        }
        print("  \(drive.bsdName.padding(toLength: 8, withPad: " ", startingAt: 0))" +
              "\(drive.model.padding(toLength: 28, withPad: " ", startingAt: 0))" +
              "\(formatBytes(drive.sizeBytes).padding(toLength: 12, withPad: " ", startingAt: 0))" +
              "\(drive.interconnect) · \(drive.location) · \(kind) · \(smart)")
    }
}

func ratingLabel(_ rating: HealthRating) -> String {
    switch rating {
    case .unknown: return "CHƯA XÁC ĐỊNH ❔"
    case .good: return "TỐT ✅"
    case .ok: return "ỔN 🙂"
    case .warning: return "CẢNH BÁO ⚠️"
    case .failing: return "ĐANG HỎNG ‼️"
    case .failed: return "HỎNG ❌"
    }
}

func printHealth(_ report: HealthReport) {
    print("  ┌─ SỨC KHOẺ TỔNG THỂ: \(ratingLabel(report.rating)) — \(report.scoreDisplay)/100")
    print("  │  \(report.coverageDescription)")
    if let lifetime = report.lifetimeLeftPercent {
        print("  │  SSD lifetime còn lại: \(lifetime)%")
    }
    for issue in report.issues {
        let icon: String
        switch issue.severity {
        case .critical: icon = "‼️"
        case .warning: icon = "⚠️"
        case .advisory: icon = "ℹ️"
        case .info: icon = "·"
        }
        print("  │  \(icon) \(issue.title): \(issue.detail)")
    }
    print("  └─")
}

func reportNVMe(_ drive: DriveInfo) {
    do {
        guard case .nvme(let reading) = try cliReading(drive) else { throw HardwareWorkerError.protocolViolation }
        let controller = reading.controller
        let smart = reading.smart

        print("── \(drive.bsdName): \(controller.model) " + String(repeating: "─", count: max(0, 40 - controller.model.count)))
        printHealth(HealthEvaluator.evaluate(nvme: reading))
        print("  Serial:               \(controller.serialNumber)")
        print("  Firmware:             \(controller.firmwareRevision)")
        print("  NVMe spec:            \(controller.specVersion ?? "—")")
        // Apple controllers report tnvmcap = 0; fall back to IOMedia size.
        let capacity = controller.totalCapacityBytes > 0
            ? controller.totalCapacityBytes : drive.sizeBytes
        print("  Total capacity:       \(formatBytes(capacity))")
        if controller.warningTempKelvin > 0 {
            print("  Temp thresholds:      warning \(Int(controller.warningTempKelvin) - 273)°C / critical \(Int(controller.criticalTempKelvin) - 273)°C")
        }
        print("")
        let warning = smart.criticalWarning
        print("  Critical warning:     0x\(String(warning.rawValue, radix: 16, uppercase: true)) \(warning.isEmpty ? "(OK)" : "⚠️")")
        if warning.contains(.spareBelowThreshold) { print("    ⚠️ Spare capacity dưới ngưỡng!") }
        if warning.contains(.temperatureError) { print("    ⚠️ Nhiệt độ ngoài ngưỡng an toàn!") }
        if warning.contains(.reliabilityDegraded) { print("    ⚠️ Độ tin cậy NVM suy giảm (media errors)!") }
        if warning.contains(.mediaReadOnly) { print("    ⚠️ Media đã chuyển sang chế độ chỉ đọc!") }
        if warning.contains(.volatileBackupFailed) { print("    ⚠️ Volatile memory backup hỏng!") }
        print("  Temperature:          \(smart.temperatureCelsius.map { "\($0)°C" } ?? "—")")
        let extraSensors = smart.temperatureSensorsKelvin.filter { $0 > 0 }
        if !extraSensors.isEmpty {
            print("  Temp sensors:         \(extraSensors.map { "\(Int($0) - 273)°C" }.joined(separator: ", "))")
        }
        print("  Available spare:      \(smart.availableSpare)% (threshold \(smart.availableSpareThreshold)%)")
        print("  Percentage used:      \(smart.percentageUsed)% (SSD lifetime left ≈ \(max(0, 100 - Int(smart.percentageUsed)))%)")
        print("  Data read:            \(smart.bytesRead.map(formatBytes) ?? "—") (\(smart.counterDisplay("dataUnitsRead")) units)")
        print("  Data written:         \(smart.bytesWritten.map(formatBytes) ?? "—") (\(smart.counterDisplay("dataUnitsWritten")) units)")
        print("  Host read commands:   \(smart.counterDisplay("hostReadCommands"))")
        print("  Host write commands:  \(smart.counterDisplay("hostWriteCommands"))")
        print("  Controller busy:      \(smart.counterDisplay("controllerBusyTimeMinutes")) minutes")
        print("  Power cycles:         \(smart.counterDisplay("powerCycles"))")
        print("  Power-on hours:       \(smart.counterDisplay("powerOnHours"))")
        print("  Unsafe shutdowns:     \(smart.counterDisplay("unsafeShutdowns"))")
        print("  Media errors:         \(smart.counterDisplay("mediaErrors"))")
        print("  Error log entries:    \(smart.counterDisplay("errorLogEntries"))")
        print("")
    } catch {
        print("── \(drive.bsdName): \(drive.model) — LỖI: \(error.localizedDescription)\n")
    }
}

func reportATA(_ drive: DriveInfo) {
    do {
        guard case .ata(let reading) = try cliReading(drive) else { throw HardwareWorkerError.protocolViolation }
        let model = reading.identify?.model ?? drive.model
        print("── \(drive.bsdName): \(model) " + String(repeating: "─", count: max(0, 40 - model.count)))
        printHealth(HealthEvaluator.evaluate(ata: reading))
        if let identify = reading.identify {
            print("  Serial:               \(identify.serialNumber)")
            print("  Firmware:             \(identify.firmwareRevision)")
            print("  Medium:               \(identify.isSolidState ? "SSD" : identify.rpm.map { "HDD \($0) rpm" } ?? "HDD")")
        }
        if let family = reading.driveFamily {
            print("  Model family:         \(family)")
        }
        if let warning = reading.driveWarning {
            print("  ⚠️ drivedb warning:    \(warning)")
        }
        if let failing = reading.overallFailurePredicted {
            print("  SMART overall:        \(failing ? "FAILING — thresholds exceeded ⚠️" : "PASSED")")
        }
        if let selfTest = reading.selfTest, selfTest.inProgress {
            if let remaining = selfTest.percentRemaining {
                print("  Self-test:            đang chạy, còn \(remaining)%")
            } else {
                print("  Self-test:            đang chạy, chưa có tiến độ hợp lệ")
            }
        }
        print("")
        print("  ID# ATTRIBUTE_NAME             FLAG  VALUE WORST THRESH TYPE     RAW")
        for attr in reading.attributes {
            let name = attr.name.padding(toLength: 26, withPad: " ", startingAt: 0)
            let flag = String(format: "0x%04x", attr.flags)
            let type = attr.isPrefail ? "Pre-fail" : "Old_age "
            let thresh = attr.threshold.map { String(format: "%5d", Int($0)) } ?? "    —"
            let marker = attr.failedNow ? "  ← FAILING NOW" : (attr.failedEver ? "  ← failed in past" : "")
            print("  \(String(format: "%3d", Int(attr.attributeID))) \(name) \(flag) \(attr.currentIsNormalized ? String(format: "%5d", Int(attr.current)) : "    —") \(attr.worstIsNormalized ? String(format: "%5d", Int(attr.worst)) : "    —") \(thresh) \(type) \(attr.rawDisplay)\(marker)")
        }
        print("")
    } catch {
        print("── \(drive.bsdName): \(drive.model) — LỖI: \(error.localizedDescription)\n")
    }
}

func reportSMART(matching bsdName: String?) {
    do {
        let drives = try cliDrives()
            .filter { !$0.isVirtual }
            .filter { bsdName == nil || $0.bsdName == bsdName }

        if drives.isEmpty {
            print(bsdName.map { "Không tìm thấy ổ \($0)." } ?? "Không tìm thấy ổ vật lý nào.")
            exit(1)
        }
        for drive in drives {
            switch drive.smartInterface {
            case .nvme:
                reportNVMe(drive)
            case .ata:
                reportATA(drive)
            case .unsupported:
                print("── \(drive.bsdName): \(drive.model) — SMART không khả dụng qua \(drive.interconnect)\n")
            }
            printVolumes(of: drive)
        }
    } catch {
        FileHandle.standardError.write(Data("Lỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

func printVolumes(of drive: DriveInfo) {
    guard let volumes = try? cliVolumes(drive) else { print("  Volume data unavailable\n"); return }
    guard !volumes.isEmpty else { return }
    print("  Volume:")
    for group in VolumeUsageReader.capacityGroups(volumes) {
        print("    \(group.displayName): \(formatBytes(group.usedBytes)) / \(formatBytes(group.totalBytes)) (\(Int(group.usedFraction * 100))%)")
    }
    print("")
}

func reportSystem() {
    if let battery = BatteryReader.read() {
        print("── PIN " + String(repeating: "─", count: 40))
        print("  Sức khoẻ:             \(battery.healthPercent)% (\(battery.maxCapacitymAh)/\(battery.designCapacitymAh) mAh)")
        print("  Chu kỳ sạc:           \(battery.cycleCount)")
        print("  Mức pin:              \(battery.chargePercent)%\(battery.isCharging ? " (đang sạc)" : "")")
        if let temp = battery.temperatureCelsius {
            print("  Nhiệt độ pin:         \(String(format: "%.1f", temp))°C")
        }
    } else {
        print("── PIN: không có (desktop?)")
    }
    print("")
    let sensors = SensorsReader.readTemperatures()
    print("── CẢM BIẾN NHIỆT (\(sensors.count)) " + String(repeating: "─", count: 24))
    for (group, celsius) in SensorsReader.summarize(sensors) {
        print("  \(group.displayName().padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(format: "%5.1f", celsius))°C")
    }
    print("")
    if let memory = MemoryReader.read() {
        print("── BỘ NHỚ " + String(repeating: "─", count: 37))
        print("  Tổng RAM:             \(formatBytes(memory.totalBytes))")
        print("  Đang dùng:            \(formatBytes(memory.usedBytes)) (\(Int(memory.usedFraction * 100))%)")
        print("  Nén:                  \(formatBytes(memory.compressedBytes))")
        print("  Swap:                 \(formatBytes(memory.swapUsedBytes)) / \(formatBytes(memory.swapTotalBytes))")
        print("  Áp lực:               \(memory.pressureLevel >= 4 ? "NGHIÊM TRỌNG" : memory.pressureLevel >= 2 ? "Cao" : "Bình thường")")
    }
}

switch arguments.first {
case nil, "smart":
    reportSMART(matching: arguments.count > 1 ? arguments[1] : nil)
case "system":
    reportSystem()
case "list":
    do {
        listDrives(try cliDrives())
    } catch {
        FileHandle.standardError.write(Data("Lỗi: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
case "benchmark", "bench":
    runBenchmarkCommand(arguments: Array(arguments.dropFirst()))
case "verify-capacity", "verify":
    runVerifyCapacityCommand(arguments: Array(arguments.dropFirst()))
case "workspaces":
    runWorkspaceCommand(arguments: Array(arguments.dropFirst()))
case "help", "-h", "--help":
    printUsage()
default:
    printUsage()
    exit(2)
}
