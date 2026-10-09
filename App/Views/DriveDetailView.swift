/*
 * DriveDetailView.swift — per-drive header + tabbed detail.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MDriveHealthCore

struct DriveDetailView: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @State private var reportCopied = false
    @State private var reportError: String?
    @State private var isEjecting = false
    @State private var ejectBlockers: [String]?
    @State private var ejectError: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Tổng quan"
        case attributes = "Thuộc tính SMART"
        case history = "Lịch sử"
        case benchmark = "Tốc độ"
        case selfTest = "Self-test"
        case info = "Thiết bị"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .overview

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Group {
                switch tab {
                case .overview:
                    OverviewTab(snapshot: snapshot)
                case .attributes:
                    AttributesTab(snapshot: snapshot)
                case .history:
                    HistoryTab(snapshot: snapshot)
                case .benchmark:
                    BenchmarkTab(snapshot: snapshot)
                case .selfTest:
                    SelfTestTab(snapshot: snapshot)
                case .info:
                    DeviceInfoTab(snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(snapshot.drive.model)
        .toolbar {
            if !snapshot.drive.isInternal, !snapshot.volumes.isEmpty {
                ToolbarItem {
                    Button {
                        eject(force: false)
                    } label: {
                        if isEjecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Đẩy an toàn", systemImage: "eject")
                        }
                    }
                    .disabled(isEjecting || !store.operations.canBegin(driveID: snapshot.id, kind: .eject))
                    .help("Unmount toàn bộ volume của ổ này; nếu bị kẹt sẽ chỉ ra app nào đang giữ file")
                }
            }
            ToolbarItem {
                Menu {
                    Button {
                        copyReport()
                    } label: {
                        Label("Sao chép báo cáo", systemImage: "doc.on.doc")
                    }
                    Button {
                        saveReport()
                    } label: {
                        Label("Lưu báo cáo ra file…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Label(reportCopied ? "Đã sao chép!" : "Báo cáo",
                          systemImage: reportCopied ? "checkmark" : "square.and.arrow.up")
                }
                .help("Xuất báo cáo text để đăng lên group hoặc gửi khi cần trợ giúp")
            }
        }
        .confirmationDialog(
            "Không đẩy được — có ứng dụng đang giữ file trên ổ",
            isPresented: Binding(get: { ejectBlockers != nil },
                                 set: { if !$0 { ejectBlockers = nil } }),
            titleVisibility: .visible
        ) {
            Button("Đẩy mạnh (force)", role: .destructive) {
                eject(force: true)
            }
            Button("Huỷ", role: .cancel) {}
        } message: {
            Text(String(localized: "eject.blockers",
                        defaultValue: "Đang giữ file: \((ejectBlockers ?? []).joined(separator: ", ")). Đóng các app này rồi thử lại, hoặc đẩy mạnh (có thể mất dữ liệu chưa lưu của chính các app đó)."))
        }
        .alert("Không xuất được báo cáo", isPresented: Binding(get: { reportError != nil }, set: { if !$0 { reportError = nil } })) {
            Button("Thử lưu lại") { saveReport() }
            Button("Đóng", role: .cancel) {}
        } message: { Text(reportError ?? "") }
        .alert("Không đẩy được ổ",
               isPresented: Binding(get: { ejectError != nil },
                                    set: { if !$0 { ejectError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(ejectError ?? "")
        }
    }

    private func eject(force: Bool) {
        isEjecting = true
        Task {
            let outcome = await store.eject(snapshot.drive,
                                                   volumes: snapshot.volumes,
                                                   force: force)
            isEjecting = false
            switch outcome {
            case .ejected:
                await store.refresh()
            case .blocked(let names):
                ejectBlockers = names
            case .failed(let message):
                ejectError = message
            case .stalled(let message, _):
                ejectError = message
            }
        }
    }

    /// Fetches the latest benchmark off the main thread, then builds the
    /// report (the sqlite read must not block a toolbar click).
    private func buildReport() async -> String {
        let key = snapshot.identity.key
        var benchmark: BenchmarkResult?
        var historyWarning: String?
        do { benchmark = try await store.history.run("report.query:" + key) { try await $0.latestBenchmark(driveKey: key) } }
        catch { historyWarning = error.localizedDescription }
        var report = ReportGenerator.text(for: snapshot, ioErrors24h: store.ioScanIssue == nil ? store.ioErrorCounts[snapshot.drive.bsdName] : nil, latestBenchmark: benchmark)
        if let issue = store.ioScanIssue {
            report += "\n" + String(localized: "ioScan.reportIncomplete", defaultValue: "Kernel log chưa đọc được đầy đủ: \(issue)") + "\n"
        }
        if !snapshot.identity.isPersistent {
            report += "\n" + String(localized: "identity.reportLimited", defaultValue: "Danh tính ổ chưa chắc chắn; lịch sử chỉ được liên kết trong phiên hiện tại.") + "\n"
        }
        if let historyWarning {
            report += "\n" + String(localized: "report.historyUnavailable", defaultValue: "Không đọc được lịch sử benchmark: \(historyWarning)") + "\n"
        }
        return report
    }

    private func copyReport() {
        Task {
            let report = await buildReport()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(report, forType: .string) else {
                reportError = String(localized: "report.clipboardFailed", defaultValue: "Không ghi được báo cáo vào clipboard.")
                return
            }
            reportCopied = true
            try? await Task.sleep(for: .seconds(2))
            reportCopied = false
        }
    }

    private func saveReport() {
        Task {
            let report = await buildReport()
            let panel = NSSavePanel()
            let model = snapshot.drive.model.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")
            panel.nameFieldStringValue = "MDriveHealth-\(model).txt"
            panel.allowedContentTypes = [.plainText]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task {
                    do {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            DispatchQueue.global(qos: .utility).async {
                                continuation.resume(with: Result { try ReportDocumentWriter.write(report, to: url) })
                            }
                        }
                        reportError = nil
                    } catch { reportError = error.localizedDescription }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.drive.isInternal ? "internaldrive.fill" : "externaldrive.fill")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.drive.model).font(.title3.weight(.semibold))
                HStack(spacing: 8) {
                    Text(Format.bytes(snapshot.drive.sizeBytes))
                    Text("·")
                    Text(snapshot.drive.interconnect)
                    Text("·")
                    Text(snapshot.drive.isSolidState ? "SSD" : "HDD")
                    if let serial = snapshot.drive.serialNumber {
                        Text("·")
                        Text("S/N \(serial)").textSelection(.enabled)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let health = snapshot.health {
                HealthBadge(rating: health.rating)
            }
        }
        .padding()
    }
}
