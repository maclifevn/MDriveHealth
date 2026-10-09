/* The same explicit authorization UI in onboarding and Settings. GPL-3.0-or-later. */
import SwiftUI
import AppKit

struct LoginItemControl: View {
    @Bindable var controller: LoginItemController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("login.request", isOn: Binding(get: { controller.status.isRequested }, set: { controller.setRequested($0) }))
                .toggleStyle(.switch)
                .disabled(!controller.canChange)
                .help("login.request.help")
                .accessibilityIdentifier("login.request")
            Text(controller.status.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("login.status")
            if let error = controller.errorMessage {
                Label {
                    Text(error).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StatusPalette.danger.foreground) }
                    .font(.caption)
                    .accessibilityIdentifier("login.error")
            }
            if controller.isBusy {
                HStack { ProgressView().controlSize(.small); Text("login.changing").font(.caption) }
            } else if controller.status == .requiresApproval {
                Button("login.openSettings") { controller.openSettings() }
                    .disabled(controller.isShuttingDown)
                    .accessibilityIdentifier("login.openSettings")
            }
            if controller.errorMessage != nil || !controller.status.canChange {
                Button("login.refresh") { controller.refresh() }
                    .disabled(controller.isBusy || controller.isShuttingDown)
                    .accessibilityIdentifier("login.refresh")
            }
        }
        .task { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in controller.refresh() }
    }
}
