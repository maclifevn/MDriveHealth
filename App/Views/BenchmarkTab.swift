/*
 * BenchmarkTab.swift — disk speed benchmark UI: dual live gauges, live chart,
 * result cards, and history. Runs the shared BenchmarkRunner.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import Charts
import MDriveHealthCore

struct BenchmarkTab: View {
    let snapshot: DriveSnapshot
    @Environment(DriveStore.self) private var store
    @Environment(BenchmarkRunner.self) private var runner
    @Environment(CapacityVerifyRunner.self) private var capacityRunner
    @Environment(\.shareImageDirectory) private var shareDirectory

    private enum Mode: String, CaseIterable, Identifiable {
        case speed = "Tốc độ đọc/ghi"
        case capacity = "Kiểm tra dữ liệu"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .speed
    @State private var selectedVolumeID: String?

    /// A run in progress on THIS drive pins its own mode — flipping the
    /// picker must never hide a live progress view and its Cancel button.
    private var effectiveMode: Mode {
        if runner.isRunning, runner.ownerDriveID == snapshot.id { return .speed }
        if capacityRunner.isRunning, capacityRunner.ownerDriveID == snapshot.id { return .capacity }
        return mode
    }
    private var measurementIsRunningHere: Bool {
        (runner.isRunning && runner.ownerDriveID == snapshot.id)
            || (capacityRunner.isRunning && capacityRunner.ownerDriveID == snapshot.id)
    }
    @State private var fileSize: UInt64 = BenchmarkConfig.defaultFileSize
    @State private var includeRandom = false
    @State private var queueDepth = 1
    @State private var history: [BenchmarkResult] = []
    @State private var historyError: String?
    @State private var historyKey: String?
    @State private var historyRequest = UUID()
    @State private var previousForDelta: BenchmarkResult?
    @State private var shareURL: URL?
    @State private var capacityShareURL: URL?
    @State private var capacityReview: VolumeUsage?

    private var selectedVolume: VolumeUsage? {
        snapshot.volumes.first { $0.bsdName == selectedVolumeID } ?? snapshot.volumes.first
    }

    private var config: BenchmarkConfig {
        BenchmarkConfig(fileSizeBytes: fileSize, includeRandomPhases: includeRandom,
                        queueDepth: queueDepth)
    }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if (runner.isStalled && runner.ownerDriveID == snapshot.id) || (capacityRunner.isStalled && capacityRunner.ownerDriveID == snapshot.id) {
                    Label("Ổ chưa trả lời. Đã yêu cầu hủy; chờ ứng dụng dọn xong dữ liệu thử trước khi thao tác tiếp.", systemImage: "hourglass")
                        .font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                }
                Picker("Chế độ", selection: $mode) {
                    ForEach(Mode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let historyError {
                    Label(historyError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                    Button("Thử lại") { Task { await store.retryHistory(); await reloadHistory() } }
                }
                if runner.unsavedResults.contains(where: { $0.driveKey == snapshot.identity.key }) {
                    Label("Kết quả benchmark chưa được lưu vào lịch sử.", systemImage: "exclamationmark.triangle").foregroundStyle(StatusPalette.caution.foreground)
                    if let error = runner.persistenceError { Text(error).font(.caption) }
                    Button("Thử lưu lại") { Task { await runner.retrySaving(reconnect: true); await reloadHistory() } }
                        .disabled(runner.isSaving)
                }
                if capacityRunner.unsavedResults.contains(where: { $0.intent.driveKey == snapshot.identity.key }) {
                    Label("measurement.resultsNotSaved", systemImage: "exclamationmark.triangle").foregroundStyle(StatusPalette.caution.foreground)
                    if let error = capacityRunner.persistenceError { Text(error).font(.caption).textSelection(.enabled) }
                    Button("Thử lưu lại") { Task { await capacityRunner.retrySaving(reconnect: true) } }.disabled(capacityRunner.isSaving)
                }
                if runner.ownerDriveID == snapshot.id, let message = runner.recoveredResultMessage {
                    Label("measurement.resultRecovered", systemImage: "arrow.counterclockwise")
                    Text(message).font(.caption).textSelection(.enabled)
                }
                if capacityRunner.ownerDriveID == snapshot.id, let message = capacityRunner.recoveredResultMessage {
                    Label("measurement.resultRecovered", systemImage: "arrow.counterclockwise")
                    Text(message).font(.caption).textSelection(.enabled)
                }
                if runner.journalCleanupIssues.values.contains(where: { $0.driveKey == snapshot.identity.key })
                    || capacityRunner.journalCleanupIssues.values.contains(where: { $0.driveKey == snapshot.identity.key }) {
                    Label("measurement.journalCleanupWarning", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                }
                if snapshot.volumes.isEmpty {
                    ContentUnavailableView(
                        "Không có volume nào mount trên ổ này",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("Benchmark cần một volume đã mount và ghi được. Ổ chưa định dạng hoặc chưa mount thì không đo được."))
                        .frame(maxWidth: .infinity)
                } else if runner.isBusyElsewhere(driveID: snapshot.id)
                            || capacityRunner.isBusyElsewhere(driveID: snapshot.id) {
                    busyElsewhereBox
                } else if effectiveMode == .speed {
                    content
                    if !history.isEmpty {
                        historySection
                    }
                } else {
                    capacityContent
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .id("measurement-top")
        }
        .task(id: measurementIsRunningHere ? snapshot.id : nil) {
            if measurementIsRunningHere { proxy.scrollTo("measurement-top", anchor: .top) }
        }
        }
        .sheet(item: $capacityReview) { volume in
            CapacitySafetyReview(volume: volume) { config in
                capacityRunner.start(snapshot: snapshot, volume: volume, config: config)
                capacityReview = nil
            }
        }
        .task(id: snapshot.identity.key) { await reloadHistory() }
        .onChange(of: runner.historyRevision) { Task { await reloadHistory() } }
    }

    @ViewBuilder
    private var content: some View {
        // finished/failed states belong to the drive that ran the benchmark
        // (runner.ownerDriveID); every other drive's tab shows its own config.
        switch runner.state {
        case .idle:
            // A previous run's numbers are more useful than a bare form.
            if let latest = history.last {
                resultView(latest, live: false)
            }
            configCard
        case .running(let phase):
            runningView(phase: phase)
        case .finished(let result) where runner.ownerDriveID == snapshot.id:
            resultView(result, live: true)
        case .failed(let message) where runner.ownerDriveID == snapshot.id:
            failedBanner(message)
            configCard
        case .finished, .failed:
            if let latest = history.last {
                resultView(latest, live: false)
            }
            configCard
        }
    }

    /// Ring scale in MB/s: the smallest "speed class" tier that fits, so a
    /// 30 MB/s USB stick fills 30% of a 100-tier ring instead of looking as
    /// "full" as a 3000 MB/s NVMe (relative scaling made every drive ~87%).
    private func gaugeScale(for maxMBps: Double) -> Double {
        let tiers: [Double] = [100, 250, 500, 1_000, 2_000, 4_000, 8_000]
        return tiers.first { maxMBps <= $0 } ?? (maxMBps * 1.1)
    }

    // MARK: - Config

    private var configCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Đo tốc độ đọc/ghi")
                .font(.headline)

            Picker("Volume", selection: $selectedVolumeID) {
                ForEach(snapshot.volumes) { volume in
                    Text(String(localized: "benchmark.volumeOption",
                                defaultValue: "\(volume.name) — trống \(Format.bytes(volume.availableBytes))"))
                        .tag(Optional(volume.bsdName))
                }
            }

            Picker("Cỡ dữ liệu đo", selection: $fileSize) {
                ForEach(BenchmarkConfig.presetFileSizes, id: \.self) { size in
                    Text(Format.bytes(size)).tag(size)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Đo thêm Random 4K (~16 giây)", isOn: $includeRandom)

            Picker("Độ sâu hàng đợi", selection: $queueDepth) {
                Text("Tiêu chuẩn (QD1)").tag(1)
                Text("Cao (QD8)").tag(8)
            }
            .pickerStyle(.segmented)

            if let volume = selectedVolume,
               volume.availableBytes < config.requiredFreeBytes {
                Label(String(localized: "benchmark.notEnoughSpace",
                             defaultValue: "Không đủ dung lượng trống trên volume này (cần ~\(Format.bytes(config.requiredFreeBytes)))."),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(StatusPalette.caution.foreground)
            }

            HStack {
                Button {
                    startRun()
                } label: {
                    Label("Bắt đầu đo", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                Spacer()
            }

            warningBox
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private var canStart: Bool {
        guard let volume = selectedVolume,
              store.operations.canBegin(driveID: snapshot.id, kind: .benchmark) else { return false }
        return volume.availableBytes >= config.requiredFreeBytes
    }

    private var canStartCapacity: Bool {
        selectedVolume != nil && selectedVolume?.mountPoint != "/"
            && store.operations.canBegin(driveID: snapshot.id, kind: .capacity)
    }

    private var firmwareTestBlocksMeasurement: Bool {
        store.operations.firmwareTests[snapshot.id] != nil
            || store.operations.trackedSelfTests.contains(snapshot.id)
    }

    private var warningBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "benchmark.warn.write",
                         defaultValue: "Benchmark ghi \(Format.bytes(fileSize)) dữ liệu lên volume rồi tự xoá — tránh dùng ổ nặng trong lúc đo."),
                  systemImage: "info.circle")
            Label(String.localizedStringWithFormat(String(localized: "benchmark.warn.queue", defaultValue: "Độ sâu hàng đợi: QD%ld. Chỉ so sánh với phép đo có cùng cấu hình."), queueDepth),
                  systemImage: "gauge.with.dots.needle.33percent")
            if selectedVolume?.mountPoint == "/" {
                Label("benchmark.warn.bootVolume", systemImage: "internaldrive")
            }
            if firmwareTestBlocksMeasurement {
                Label("measurement.waitForFirmwareTest",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StatusPalette.caution.foreground)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Running

    private func runningView(phase: BenchmarkPhase) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if runner.isCleaning { Text("lifecycle.cleaning").font(.headline) }
                else if runner.isCancelling { Text("lifecycle.measurementStopping").font(.headline) }
                else { Text(phaseName(phase)).font(.headline) }
                Spacer()
                Button(role: .cancel) { runner.cancel() } label: {
                    Label("Huỷ", systemImage: "stop.fill")
                }
                .disabled(runner.isCleaning || runner.isCancelling)
            }
            gaugeRow(write: liveWriteMBps, read: liveReadMBps, scale: liveScale)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Spacer()
                    Text(Format.speed((runner.progress?.instantaneousBytesPerSecond ?? 0)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                }
                if runner.isCleaning || runner.isCancelling { ProgressView().controlSize(.small) }
                else { ProgressView(value: runner.progress?.fractionCompleted ?? 0) }
            }

            liveChart

        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private var liveChart: some View {
        Chart(runner.samples) { sample in
            LineMark(x: .value("Giây", sample.elapsed),
                     y: .value("MB/s", sample.megabytesPerSecond))
                .foregroundStyle(by: .value("Pha", phaseName(sample.phase)))
                .interpolationMethod(.monotone)
        }
        .chartYAxisLabel("MB/s")
        .chartLegend(.hidden)
        .frame(height: 150)
        .accessibilityLabel(Text("Biểu đồ tốc độ trực tiếp"))
    }

    // Incrementally maintained by the runner — no per-frame array scans.
    private var liveWriteMBps: Double { runner.lastWriteMBps }
    private var liveReadMBps: Double { runner.lastReadMBps }
    private var liveScale: Double { gaugeScale(for: runner.peakMBps) }

    // MARK: - Result

    /// `live: true` = the run that just finished (deltas + "Run again");
    /// `live: false` = a persisted result shown in the idle state.
    private func resultView(_ result: BenchmarkResult, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !live {
                Label("Kết quả gần nhất", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }

            gaugeRow(write: result.sequentialWriteBytesPerSec / 1e6,
                     read: result.sequentialReadBytesPerSec / 1e6,
                     scale: gaugeScale(for: max(result.sequentialWriteBytesPerSec,
                                                result.sequentialReadBytesPerSec) / 1e6))

            // Two equal columns → 2×2 with random on, one clean row with it
            // off; never a lone card wrapping to its own line.
            let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]
            LazyVGrid(columns: columns, spacing: 10) {
                resultCard("Tuần tự · Ghi", result.sequentialWriteBytesPerSec,
                           delta: live ? previousForDelta?.sequentialWriteBytesPerSec : nil)
                resultCard("Tuần tự · Đọc", result.sequentialReadBytesPerSec,
                           delta: live ? previousForDelta?.sequentialReadBytesPerSec : nil)
                if let rw = result.randomWriteBytesPerSec {
                    resultCard("Random 4K · Ghi", rw, iops: result.randomWriteIOPS,
                               delta: live ? previousForDelta?.randomWriteBytesPerSec : nil)
                }
                if let rr = result.randomReadBytesPerSec {
                    resultCard("Random 4K · Đọc", rr, iops: result.randomReadIOPS,
                               delta: live ? previousForDelta?.randomReadBytesPerSec : nil)
                }
            }

            Text(String(localized: "benchmark.result.caption.qd",
                        defaultValue: "\(result.volumeName) · \(Format.bytes(result.fileSizeBytes)) · QD\(result.queueDepth) · \(result.capturedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                if live {
                    Button {
                        runner.reset()
                    } label: {
                        Label("Chạy lại", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let shareURL {
                    ShareLink(item: shareURL) {
                        Label("Chia sẻ ảnh", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
        .task(id: result) {
            shareURL = ShareCardRenderer.pngURL(
                for: BenchmarkShareCard(drive: snapshot.drive,
                                        health: snapshot.health, result: result),
                name: "MDriveHealth-Speed", directory: shareDirectory)
        }
    }

    private func resultCard(_ title: LocalizedStringKey, _ bytesPerSec: Double,
                            iops: Double? = nil, delta: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Format.speed(bytesPerSec))
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
            if let iops {
                Text(Format.iops(iops)).font(.caption2).foregroundStyle(.secondary)
            }
            if let comparison = BenchmarkDisplay.comparison(current: bytesPerSec, previous: delta) {
                switch comparison {
                case .faster(let percent):
                    Text(String(localized: "benchmark.delta.up", defaultValue: "▲ \(percent)% nhanh hơn lần trước"))
                        .font(.caption2).foregroundStyle(StatusPalette.positive.foreground)
                case .slower(let percent):
                    Text(String(localized: "benchmark.delta.down", defaultValue: "▼ \(percent)% chậm hơn lần trước"))
                        .font(.caption2).foregroundStyle(StatusPalette.caution.foreground)
                case .similar:
                    Text("≈ lần trước").font(.caption2).foregroundStyle(.secondary)
                case .unavailable:
                    Text("benchmark.delta.unavailable").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Shared pieces

    private func gaugeRow(write: Double, read: Double, scale: Double) -> some View {
        HStack(spacing: 28) {
            Spacer()
            RingGauge(value: scale > 0 ? write / scale : 0,
                      label: BenchmarkDisplay.number(write), caption: "Ghi (MB/s)", color: .accentColor)
            RingGauge(value: scale > 0 ? read / scale : 0,
                      label: BenchmarkDisplay.number(read), caption: "Đọc (MB/s)", color: .teal)
            Spacer()
        }
    }

    private func failedBanner(_ message: String) -> some View {
        Label(message, systemImage: "xmark.octagon")
            .font(.callout)
            .foregroundStyle(StatusPalette.danger.foreground)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var busyElsewhereBox: some View {
        Label("measurement.busyElsewhere",
              systemImage: "hourglass")
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lịch sử đo").font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(history.reversed().enumerated()), id: \.offset) { index, result in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(String(localized: "benchmark.history.sub",
                                        defaultValue: "\(result.volumeName) · \(Format.bytes(result.fileSizeBytes))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(localized: "benchmark.history.rates",
                                    defaultValue: "W \(BenchmarkDisplay.number(result.sequentialWriteBytesPerSec / 1e6)) · R \(BenchmarkDisplay.number(result.sequentialReadBytesPerSec / 1e6)) MB/s"))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    if index < history.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Actions

    private func startRun() {
        guard canStart, let volume = selectedVolume else { return }
        // Delta baseline must be a comparable run: same volume, same test
        // size, same random setting — else a 512 MB run gets compared against
        // a 5 GB run on another volume and the badge lies.
        let runConfig = config
        previousForDelta = history.last { previous in
            previous.volumeBSDName == volume.bsdName
                && previous.fileSizeBytes == runConfig.fileSizeBytes
                && previous.queueDepth == runConfig.queueDepth
                && (previous.randomWriteBytesPerSec != nil) == runConfig.includeRandomPhases
        }
        runner.start(snapshot: snapshot, volume: volume, config: runConfig)
    }

    private func reloadHistory() async {
        // Reset a selection carried over from another drive (the view keeps
        // its @State across drive switches via positional identity).
        if selectedVolumeID == nil
            || !snapshot.volumes.contains(where: { $0.bsdName == selectedVolumeID }) {
            selectedVolumeID = snapshot.volumes.first?.bsdName
        }
        let key = snapshot.identity.key, token = UUID()
        historyRequest = token
        if historyKey != key { history = []; historyError = nil; historyKey = key }
        do {
            let results = try await store.history.run("benchmark.query:" + key) { try await $0.benchmarks(driveKey: key, since: .distantPast) }
            guard historyRequest == token, !Task.isCancelled else { return }
            history = results; historyError = nil
        } catch {
            guard historyRequest == token, !Task.isCancelled else { return }
            historyError = error.localizedDescription
        }
    }

    // MARK: - Capacity verification (fake-drive check)

    @ViewBuilder
    private var capacityContent: some View {
        switch capacityRunner.state {
        case .idle:
            capacityConfigCard
        case .running(let phase):
            capacityRunningView(phase)
        case .finished(let result) where capacityRunner.ownerDriveID == snapshot.id:
            capacityResultView(result)
        case .failed(let message) where capacityRunner.ownerDriveID == snapshot.id:
            failedBanner(message)
            capacityConfigCard
        case .finished, .failed:
            capacityConfigCard
        }
    }

    private var capacityConfigCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Kiểm tra dữ liệu trên dung lượng trống")
                .font(.headline)
            Text("Ghi dữ liệu kiểm tra vào dung lượng trống rồi đọc lại. Kết quả phát hiện dữ liệu bị hỏng trong phần đã kiểm tra; không tự xác định dung lượng vật lý hoặc chứng minh ổ gian lận.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Volume", selection: $selectedVolumeID) {
                ForEach(snapshot.volumes) { volume in
                    Text(String(localized: "benchmark.volumeOption",
                                defaultValue: "\(volume.name) — trống \(Format.bytes(volume.availableBytes))"))
                        .tag(Optional(volume.bsdName))
                }
            }

            HStack {
                Button {
                    startCapacityVerify()
                } label: {
                    Label("Bắt đầu kiểm tra", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStartCapacity)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                if firmwareTestBlocksMeasurement {
                    Label("measurement.waitForFirmwareTest", systemImage: "hourglass")
                        .foregroundStyle(StatusPalette.caution.foreground)
                }
                if let volume = selectedVolume {
                    Label(String(localized: "capacity.warn.size",
                                 defaultValue: "Sẽ ghi ~\(Format.bytes(volume.availableBytes)) rồi đọc lại toàn bộ — ổ càng lớn càng lâu (có thể hàng giờ với ổ chậm)."),
                          systemImage: "clock")
                }
                Label("Ổ khai khống có thể ghi vòng và làm hỏng dữ liệu sẵn có. Chỉ kiểm tra volume đã sao lưu; ưu tiên ổ ngoài trống có thể xóa bỏ.",
                      systemImage: "exclamationmark.triangle")
                if selectedVolume?.mountPoint == "/" {
                    Label("Không chạy kiểm tra dung lượng trên volume khởi động.", systemImage: "lock.shield")
                }
                Label("Đừng ghi thêm dữ liệu vào ổ trong lúc kiểm tra.",
                      systemImage: "hand.raised")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private func capacityRunningView(_ phase: CapacityVerifyPhase) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if capacityRunner.isCleaning { Text("lifecycle.cleaning").font(.headline) }
                else if capacityRunner.isCancelling { Text("lifecycle.measurementStopping").font(.headline) }
                else { Text(phase == .filling
                     ? "Đang ghi dữ liệu kiểm tra…"
                     : "Đang đọc lại & so khớp…")
                    .font(.headline) }
                Spacer()
                Text(Format.speed(capacityRunner.progress?.instantaneousBytesPerSecond ?? 0))
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
            if capacityRunner.isCleaning || capacityRunner.isCancelling { ProgressView().controlSize(.small) }
            else { ProgressView(value: capacityRunner.progress?.fractionCompleted ?? 0) }
            if let progress = capacityRunner.progress {
                Text(String(localized: "capacity.progress",
                            defaultValue: "\(Format.bytes(progress.bytesProcessed)) / \(Format.bytes(progress.totalBytes))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button(role: .cancel) {
                capacityRunner.cancel()
            } label: {
                Label("Huỷ", systemImage: "stop.fill")
            }
            .disabled(capacityRunner.isCleaning || capacityRunner.isCancelling)
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
    }

    private func capacityResultView(_ result: CapacityVerifyResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(result.summaryTitle, systemImage: result.symbolName)
                .font(.title3.weight(.bold))
                .foregroundStyle(capacityResultColor(result.verdict))
            Text(result.summaryDetail)
                .fixedSize(horizontal: false, vertical: true)

            Text(String(localized: "capacity.result.caption",
                        defaultValue: "\(result.volumeName) · ghi \(Format.speed(result.writeBytesPerSec)) · đọc \(Format.speed(result.readBytesPerSec)) · \(result.capturedAt.formatted(date: .abbreviated, time: .shortened))"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    capacityRunner.reset()
                } label: {
                    Label("Chạy lại", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                if let capacityShareURL {
                    ShareLink(item: capacityShareURL) {
                        Label("Chia sẻ ảnh", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .padding(14)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .combine)
        .task(id: result) {
            capacityShareURL = ShareCardRenderer.pngURL(
                for: CapacityShareCard(drive: snapshot.drive, result: result),
                name: "MDriveHealth-Capacity", directory: shareDirectory)
        }
    }

    private func startCapacityVerify() {
        guard canStartCapacity, let volume = selectedVolume else { return }
        capacityReview = volume
    }

    private func capacityResultColor(_ verdict: CapacityVerifyResult.Verdict) -> Color {
        verdict.statusPalette.foreground
    }

    private func phaseName(_ phase: BenchmarkPhase) -> String {
        switch phase {
        case .sequentialWrite: return String(localized: "benchmark.phase.seqWrite", defaultValue: "Ghi tuần tự")
        case .sequentialRead: return String(localized: "benchmark.phase.seqRead", defaultValue: "Đọc tuần tự")
        case .randomWrite: return String(localized: "benchmark.phase.randWrite", defaultValue: "Ghi Random 4K")
        case .randomRead: return String(localized: "benchmark.phase.randRead", defaultValue: "Đọc Random 4K")
        }
    }
}


private struct CapacitySafetyReview: View {
    let volume: VolumeUsage
    let confirm: (CapacityVerifyConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var backupConfirmed = false
    @State private var sharedSpaceConfirmed = false

    private var reserve: UInt64 { max(512 << 20, volume.availableBytes / 20) }
    private var estimatedWrite: UInt64 {
        volume.availableBytes > reserve ? volume.availableBytes - reserve : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Xem lại trước khi ghi thử").font(.title2.bold())
            Text(verbatim: "\(volume.name) · \(volume.bsdName)\n\(volume.mountPoint)")
                .textSelection(.enabled)
            Text(String(localized: "capacity.review.amount", defaultValue: "Ước tính ghi tối đa \(Format.bytes(estimatedWrite)), giữ lại ít nhất \(Format.bytes(reserve)); lượng thực tế được kiểm tra lại lúc bắt đầu. Đọc lại toàn bộ có thể mất hàng giờ."))
            Label("Firmware khai khống có thể ghi đè dữ liệu cũ dù chỉ ghi vào chỗ trống. Kết quả chỉ áp dụng cho phần đã kiểm tra.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(StatusPalette.caution.foreground)
            Toggle("Dữ liệu đã được sao lưu hoặc volume trống có thể xóa bỏ; tôi hiểu rủi ro ghi thử.", isOn: $backupConfirmed)
            if volume.sharesCapacity {
                Text("APFS dùng chung dung lượng với các volume khác trong container. Giữ các volume đó nhàn rỗi trong lúc kiểm tra.")
                Toggle("Tôi hiểu kiểm tra này dùng chỗ trống chung và có thể ảnh hưởng dung lượng khả dụng của các volume khác.", isOn: $sharedSpaceConfirmed)
            }
            HStack {
                Button("Hủy", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Bắt đầu ghi thử") {
                    confirm(CapacityVerifyConfig(reserveBytes: reserve,
                                                 dataRiskAcknowledged: backupConfirmed,
                                                 sharedCapacityRiskAcknowledged: sharedSpaceConfirmed))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!backupConfirmed || (volume.sharesCapacity && !sharedSpaceConfirmed) || estimatedWrite < 4 << 20)
            }
        }
        .padding(24)
        .frame(width: 580)
        .fixedSize(horizontal: false, vertical: true)
    }
}
