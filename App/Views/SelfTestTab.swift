/*
 * SelfTestTab.swift — SMART self-test control (ATA drives).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct SelfTestTab: View {
    let snapshot: DriveSnapshot
    var body: some View { SelfTestDriveContent(snapshot: snapshot).id(snapshot.identity.key) }
}

private struct SelfTestDriveContent: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @State private var startError: String?
    private var key: String { snapshot.identity.key }
    private var run: SelfTestRun? { store.selfTests.states[key]?.state.activeRun }
    private var logEntries: [ATASelfTestLogEntry]? { store.selfTests.logs[key]?.entries }
    private var logError: String? { store.selfTests.issues[key] }
    private var isLoadingLog: Bool { store.selfTests.busy.contains(key) }
    private var currentReading: ATASMARTReading? {
        SelfTestDisplay.latestReading(snapshot: snapshot.reading, observation: store.selfTests.readings[key])
    }
    private var currentStatus: ATASelfTestStatus? { currentReading?.selfTest }
    private var selfTestSupported: Bool? { currentReading?.selfTestSupported }
    @State private var isStarting = false

    private var isTestRunning: Bool {
        currentStatus?.inProgress == true || run != nil || store.operations.firmwareTests[snapshot.id] != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch snapshot.drive.smartInterface {
                case .ata:
                    ataContent
                    historySection
                case .nvme:
                    infoBox(
                        title: "Ứng dụng chưa hỗ trợ NVMe self-test",
                        message: "selftest.nvmeLimit")
                case .unsupported:
                    infoBox(title: "Không khả dụng",
                            message: "selftest.unsupportedCurrentInterface")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(snapshot.id)-\(snapshot.lastUpdated?.timeIntervalSince1970 ?? 0)") {
            await loadSelfTestLog()
        }
    }

    @ViewBuilder
    private var ataContent: some View {
        if let selfTest = currentStatus,
           selfTest.inProgress {
            VStack(alignment: .leading, spacing: 8) {
                Label("Self-test đang chạy", systemImage: "gearshape.2")
                    .font(.headline)
                if let remaining = selfTest.percentRemaining {
                    ProgressView(value: Double(100 - remaining), total: 100)
                    Text(String(localized: "selftest.progress",
                                defaultValue: "Còn khoảng \(remaining)%. Tiến độ tự cập nhật mỗi 30 giây."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text("selftest.progressUnknown")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("Chạy self-test").font(.headline)
            Text("selftest.execution.help")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button {
                    start(extended: false)
                } label: {
                    Label("selftest.short", systemImage: "bolt")
                }
                Button {
                    start(extended: true)
                } label: {
                    Label("selftest.extended", systemImage: "clock")
                }
            }
            .disabled(isStarting || isTestRunning || selfTestSupported != true || !snapshot.identity.isPersistent || !store.operations.canBegin(driveID: snapshot.id, kind: .selfTestStart))
            if isStarting { ProgressView().controlSize(.small) }
            if let run {
                if let acceptedAt = run.acceptedAt {
                    Text(String(localized: "selftest.accepted", defaultValue: "Firmware đã nhận lệnh lúc \(acceptedAt.formatted(date: .omitted, time: .standard)). App tiếp tục theo dõi khi tab đóng và khôi phục sau khi mở lại."))
                        .font(.caption).foregroundStyle(.secondary)
                } else if run.phase == .commandPending {
                    Text("selftest.commandUnconfirmed")
                        .font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                } else if run.phase == .observed {
                    Text("selftest.observed")
                        .font(.caption).foregroundStyle(.secondary)
                } else if run.phase == .prepared {
                    Text("selftest.prepared")
                        .font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                }
                if currentStatus?.inProgress == false {
                    Text("selftest.closeUnknown.help")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("selftest.closeUnknown") {
                        Task {
                            do { _ = try await store.observeSelfTest(snapshot.drive, closeWithoutResult: true) }
                            catch { store.selfTests.report(error, key: key) }
                        }
                    }.disabled(isStarting || isLoadingLog)
                }
            }
            if !snapshot.identity.isPersistent {
                Text("selftest.identityRequired")
                    .font(.caption).foregroundStyle(StatusPalette.caution.foreground)
            }
            if selfTestSupported != true {
                Text(selfTestSupported == false ? LocalizedStringKey("selftest.capability.unsupported") : LocalizedStringKey("selftest.capability.unknown"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let startError {
                Text(startError)
                    .font(.caption)
                    .foregroundStyle(StatusPalette.danger.foreground)
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lịch sử self-test")
                .font(.headline)
            if let completion = store.selfTests.latestCompletions[key] {
                VStack(alignment: .leading, spacing: 4) {
                    Text("selftest.lastTrackedResult").font(.callout.weight(.medium))
                    Text(completion.createdAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                    switch completion.outcome {
                    case .passed: Text("selftest.log.passed").foregroundStyle(StatusPalette.positive.foreground)
                    case .failed: Text("selftest.log.failed").foregroundStyle(StatusPalette.danger.foreground)
                    case .aborted: Text("selftest.result.aborted").foregroundStyle(.secondary)
                    case .indeterminate: Text("selftest.result.indeterminate").foregroundStyle(StatusPalette.caution.foreground)
                    }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            }
            if isLoadingLog { ProgressView().controlSize(.small) }
            if let logError {
                Text(logError).font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                Button("Thử đọc lại nhật ký") { Task { await loadSelfTestLog() } }
                    .disabled(isLoadingLog || !store.operations.canBegin(driveID: snapshot.id, kind: .selfTestLog))
            }
            if let entries = logEntries, !entries.isEmpty {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        SelfTestLogRow(entry: entry)
                        if entry.id != entries.last?.id { Divider() }
                    }
                }
                .background(.quaternary.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 8))
            } else if logEntries != nil, logError == nil {
                Text("selftest.log.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if logError == nil, !isLoadingLog {
                Text("Ổ này không cho đọc nhật ký self-test (thường do cầu nối/bridge chặn lệnh READ LOG).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadSelfTestLog() async {
        guard snapshot.drive.smartInterface == .ata, !isLoadingLog else { return }
        let drive = snapshot.drive
        do { _ = try await store.observeSelfTest(drive) }
        catch { store.selfTests.report(error, key: key) }
    }

    private func infoBox(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "info.circle").font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func start(extended: Bool) {
        guard !isStarting else { return }
        isStarting = true
        Task {
          defer { isStarting = false }
          do {
            try await store.startSelfTest(snapshot.drive, extended: extended)
            startError = nil
            // Pick up the "in progress" state right away so progress polling
            // kicks in. A refresh may already be in flight (refresh() would
            // silently drop ours) — wait it out, then read again.
            while store.isRefreshing {
                try await Task.sleep(for: .milliseconds(100))
            }
            await store.refresh(wakingSleepingDrives: false)
          } catch {
            startError = String(localized: "selftest.error",
                                defaultValue: "Không chạy được self-test: \(error.localizedDescription)")
          }
        }
    }
}

/// One row of the self-test history list.
private struct SelfTestLogRow: View {
    let entry: ATASelfTestLogEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(testTypeText)
                    .font(.callout.weight(.medium))
                Text(String(localized: "selftest.log.hours",
                            defaultValue: "Lúc ổ chạy được \(Int(clamping: entry.powerOnHours)) giờ"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(resultText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                if let lba = entry.failingLBA {
                    Text(verbatim: "LBA \(lba)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var testTypeText: String {
        switch entry.testType & 0x7f {
        case 1: return String(localized: "Test ngắn", defaultValue: "Test ngắn")
        case 2: return String(localized: "Test mở rộng", defaultValue: "Test mở rộng")
        case 3: return String(localized: "selftest.type.conveyance", defaultValue: "Test vận chuyển")
        case 4: return String(localized: "selftest.type.selective", defaultValue: "Test chọn vùng")
        default: return String(localized: "selftest.type.unknown", defaultValue: "Loại test \(Int(entry.testType))")
        }
    }

    private var symbol: String {
        if entry.inProgress { return "gearshape.2" }
        if entry.passed { return "checkmark.circle.fill" }
        if entry.wasAborted { return "minus.circle" }
        return "xmark.octagon.fill"
    }

    private var color: Color {
        if entry.inProgress { return StatusPalette.information.foreground }
        if entry.passed { return StatusPalette.positive.foreground }
        if entry.wasAborted { return .secondary }
        return StatusPalette.danger.foreground
    }

    private var resultText: String {
        if entry.inProgress {
            return String(localized: "selftest.log.running",
                          defaultValue: "Đang chạy (\(entry.percentRemaining)% còn lại)")
        }
        if entry.passed {
            return String(localized: "selftest.log.passed", defaultValue: "Đạt")
        }
        if entry.wasAborted {
            return String(localized: "selftest.log.aborted", defaultValue: "Đã huỷ")
        }
        return String(localized: "selftest.log.failed", defaultValue: "LỖI")
    }
}
