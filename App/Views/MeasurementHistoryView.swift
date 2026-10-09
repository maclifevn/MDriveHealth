/* Global results, including disconnected drives and interrupted runs. GPL-3.0-or-later. */
import SwiftUI
import MDriveHealthCore

struct MeasurementHistoryView: View {
    let controller: MeasurementRecoveryController
    var openWorkspaces: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var discardSelection: MeasurementJobRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("measurementHistory.title").font(.title2.bold())
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button("measurementHistory.refresh") { controller.requestRefresh() }.disabled(controller.isBusy)
                Button("recovery.close") { dismiss() }
            }
            Text("measurementHistory.scope").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let issue = controller.issue { Label(issue, systemImage: "exclamationmark.triangle").textSelection(.enabled) }
                    ForEach(controller.unknownEntries, id: \.self) { name in
                        VStack(alignment: .leading) {
                            Text("measurementHistory.unverified").font(.headline)
                            Text(verbatim: name).font(.system(.caption, design: .monospaced))
                            Text("recovery.preserved").font(.caption)
                        }.textSelection(.enabled)
                    }
                    ForEach(controller.jobs) { row in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(state(row)).font(.headline)
                            if let record = row.record { measurement(record) }
                            else {
                                Text(verbatim: row.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                if let intent = row.intent { Text(verbatim: intent.drive.model + " · " + intent.volume.name) }
                            }
                            if let issue = row.issue { Label(issue, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled) }
                            if row.intent?.historyPolicy == .omit {
                                Text("measurementHistory.omitted").font(.caption)
                                if let record = row.journalRecord, record.terminal != nil, row.cleanupConfirmed {
                                    Button("measurementHistory.discardOmitted", role: .destructive) { discardSelection = record }.disabled(controller.isBusy)
                                }
                            } else if row.archived { Text("measurementHistory.saved").font(.caption).foregroundStyle(.secondary) }
                            if !row.cleanupConfirmed, row.journalRecord != nil, row.state != .active {
                                Button("recovery.open", action: openWorkspaces)
                            }
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    Text("measurementHistory.archive").font(.headline).padding(.top, 8)
                    if controller.archivedRecords.isEmpty { Text("measurementHistory.empty").foregroundStyle(.secondary) }
                    ForEach(controller.archivedRecords) { record in
                        measurement(record).padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    HStack {
                        if controller.showingOlderPage { Button("measurementHistory.newest") { controller.requestRefresh() }.disabled(controller.isBusy) }
                        Spacer()
                        if controller.canLoadOlder { Button("measurementHistory.older") { controller.loadOlder() }.disabled(controller.isBusy) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }.padding(22).frame(minWidth: 620, idealWidth: 760, minHeight: 460, idealHeight: 620)
        .alert("measurementHistory.discardTitle", isPresented: Binding(get: { discardSelection != nil }, set: { if !$0 { discardSelection = nil } })) {
            Button("recovery.cancelCleanup", role: .cancel) { discardSelection = nil }
            Button("measurementHistory.discardOmitted", role: .destructive) {
                if let selected = discardSelection { controller.discardOmitted(selected) }; discardSelection = nil
            }
        } message: { Text("measurementHistory.discardDetail") }
    }
    private func measurement(_ record: MeasurementJobRecord) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: record.intent.drive.model + " · " + record.intent.volume.name).font(.headline)
            Text(record.intent.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: record.id.uuidString).font(.system(.caption, design: .monospaced))
            Text(verbatim: record.intent.writeDirectoryPath).font(.caption)
            switch record.terminal?.outcome {
            case .benchmark(let result):
                Text("measurementHistory.benchmark").font(.subheadline.bold())
                HStack {
                    Text("measurementHistory.write"); Text(verbatim: rate(result.sequentialWriteBytesPerSec))
                    Text("measurementHistory.read"); Text(verbatim: rate(result.sequentialReadBytesPerSec))
                }.font(.caption).monospacedDigit()
            case .capacity(let result):
                Text(result.summaryTitle).font(.subheadline.bold())
                Text(result.summaryDetail).font(.caption)
            case .cancelled: Text("measurementHistory.cancelled")
            case .notStarted(let reason): Text("measurementHistory.notStarted"); Text(verbatim: reason).font(.caption)
            case .failed(let reason): Text("measurementHistory.failed"); Text(verbatim: reason).font(.caption)
            case nil: Text("measurementHistory.interrupted")
            }
        }.textSelection(.enabled)
    }
    private func state(_ row: RecoveredMeasurement) -> LocalizedStringKey {
        switch row.state {
        case .active: return "measurementHistory.active"
        case .interrupted: return "measurementHistory.interrupted"
        case .completed: return "measurementHistory.recovered"
        case .acknowledged: return "measurementHistory.gcPending"
        case .unverified: return "measurementHistory.unverified"
        }
    }
    private func rate(_ bytes: Double) -> String { BenchmarkDisplay.speed(bytes) }
}
