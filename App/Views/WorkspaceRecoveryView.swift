/* Explicit recovery review UI. MDriveHealth, GPL-3.0-or-later. */
import SwiftUI
import MDriveHealthCore

struct WorkspaceRecoveryBanner: View {
    let controller: WorkspaceRecoveryController
    let reviewCount: Int
    var open: () -> Void
    var body: some View {
        if controller.hasFilesToReview || reviewCount > 0 {
            HStack {
                Label(LocalizedStringKey(reviewCount > 0 ? "recovery.cleanupAttention" : "recovery.filesFound"),
                      systemImage: "exclamationmark.triangle")
                Spacer()
                Button("recovery.open", action: open)
            }
            .font(.caption).padding(9).background(.quaternary)
        }
    }
}
struct WorkspaceRecoveryView: View {
    let controller: WorkspaceRecoveryController
    let reviews: [MeasurementWorkspaceReview]
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: WorkspaceCleanupSelection?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("recovery.title").font(.title2.bold())
                Spacer()
                Button("recovery.refresh") { controller.requestScanAll() }.disabled(controller.isBusy)
                Button("recovery.close") { dismiss() }
            }
            Text("recovery.scope").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if let issue = controller.catalogIssue { Label(issue, systemImage: "exclamationmark.triangle") }
                    if !reviews.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("recovery.pendingRuns", systemImage: "exclamationmark.triangle").font(.headline)
                            Text("recovery.pendingDetail").font(.caption)
                            ForEach(reviews) { review in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: review.id.uuidString).font(.system(.caption, design: .monospaced))
                                    Text(verbatim: review.volume.name + " — " + review.writeDirectoryPath).font(.caption)
                                    Text(verbatim: review.message).font(.caption).foregroundStyle(.secondary)
                                }.textSelection(.enabled)
                            }
                        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if controller.records.isEmpty {
                        Text("recovery.noVolumes").foregroundStyle(.secondary)
                    }
                    ForEach(controller.records) { record in
                        volume(record)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }
        .padding(22).frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 600)
        .sheet(item: $confirmation) { selection in
            WorkspaceCleanupConfirmation(controller: controller, selection: selection)
        }
    }
    private func volume(_ record: WorkspaceRecoveryVolume) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(record.target.volume.name, systemImage: "externaldrive").font(.headline)
                Spacer()
                if record.state == .scanning || record.state == .cleaning { ProgressView().controlSize(.small) }
                Text(state(record)).font(.caption).foregroundStyle(.secondary)
            }
            Text(verbatim: record.target.parentPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let date = record.lastScanned {
                HStack(spacing: 5) { Text("recovery.lastScan"); Text(date, style: .time) }.font(.caption).foregroundStyle(.secondary)
            }
            if let error = record.displayError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).textSelection(.enabled) }
            if !record.isCurrent, record.scan != nil { Text("recovery.stale").font(.caption).foregroundStyle(.secondary) }
            if let scan = record.scan {
                if record.isCurrent, scan.complete, scan.leftovers.isEmpty { Text("recovery.empty").font(.caption) }
                ForEach(scan.leftovers) { entry in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(LocalizedStringKey(entry.status == .recoverable ? "recovery.verified" : "recovery.unverified")).font(.caption.bold())
                            Spacer()
                            Text(recoveryBytes(entry.bytes)).font(.caption).monospacedDigit()
                        }
                        Text(verbatim: entry.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        if let diagnostic = entry.diagnostic { Text(verbatim: diagnostic).font(.caption).textSelection(.enabled) }
                        if entry.status == .recoverable {
                            Button("recovery.reviewCleanup", role: .destructive) {
                                confirmation = controller.selection(recordID: record.id, name: entry.name)
                            }.disabled(controller.selection(recordID: record.id, name: entry.name) == nil)
                        } else { Text("recovery.preserved").font(.caption).foregroundStyle(.secondary) }
                    }.padding(11).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            if record.attached, !record.ambiguous, record.target.hasStableIdentity {
                Button("recovery.refreshVolume") { controller.requestScan(record.id) }.disabled(controller.isBusy)
            }
        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 12))
    }
    private func state(_ record: WorkspaceRecoveryVolume) -> LocalizedStringKey {
        if !record.attached { return "recovery.offline" }
        switch record.state {
        case .pending: return "recovery.pending"
        case .scanning: return "recovery.scanning"
        case .cleaning: return "recovery.cleaning"
        case .deferred: return "recovery.deferredLabel"
        case .unavailable: return "recovery.unavailable"
        case .ready: return record.scan?.complete == true ? "recovery.complete" : "recovery.partial"
        }
    }
}
struct WorkspaceCleanupConfirmation: View {
    let controller: WorkspaceRecoveryController
    let selection: WorkspaceCleanupSelection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("recovery.confirmTitle", systemImage: "trash").font(.headline)
            Text(verbatim: selection.target.volume.name)
            Text(verbatim: selection.leftover.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(recoveryBytes(selection.leftover.bytes)).monospacedDigit()
            Text("recovery.confirmDetail").font(.caption)
            if !controller.isCurrent(selection) { Text("recovery.selectionChanged").font(.caption) }
            HStack {
                Button("recovery.cancelCleanup", role: .cancel) { dismiss() }
                Spacer()
                Button("recovery.confirmCleanup", role: .destructive) {
                    dismiss(); Task { await controller.cleanup(selection) }
                }.disabled(!controller.isCurrent(selection))
            }
        }.padding(24).frame(width: 510)
    }
}
private func recoveryBytes(_ value: UInt64?) -> String {
    guard let value else { return "—" }
    if value <= UInt64(Int64.max) { return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file) }
    return String(value) + " B"
}
