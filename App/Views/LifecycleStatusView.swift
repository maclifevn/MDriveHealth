/* Shutdown progress and recoverable failure. MDriveHealth, GPL-3.0-or-later. */
import SwiftUI

struct LifecycleStatusView: View {
    let lifecycle: ApplicationLifecycle
    var resumed: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: lifecycle.failure == nil ? "hourglass" : "exclamationmark.triangle")
                .font(.headline)
            if let message = lifecycle.failure {
                ScrollView { Text(message).foregroundStyle(.primary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 170)
                HStack {
                    Button("lifecycle.resume") { Task { await lifecycle.resume(); if lifecycle.failure == nil { resumed() } } }
                    Spacer()
                    Button("lifecycle.retry") { lifecycle.retry() }.buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 12) { ProgressView().controlSize(.small); Text(status) }
                Text("lifecycle.waitDetail").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
    private var title: LocalizedStringKey { lifecycle.kind == .relaunch ? "lifecycle.relaunchTitle" : "lifecycle.quitTitle" }
    private var status: LocalizedStringKey {
        switch lifecycle.phase {
        case .saving: return "lifecycle.saving"
        case .closing: return "lifecycle.closing"
        case .launching: return "lifecycle.launching"
        default: return "lifecycle.waiting"
        }
    }
}
