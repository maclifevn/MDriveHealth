/* Manual update controls; actions can be isolated in native fixtures. GPL-3.0-or-later. */
import SwiftUI

struct UpdateCheckView: View {
    @Bindable var controller: UpdateCheckController
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Kiểm tra bản cập nhật…") { controller.check() }
                    .disabled(controller.isBusy)
                    .accessibilityIdentifier("update.check")
                if controller.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(Text("update.checking"))
                    Button("update.cancel") { controller.cancel() }
                        .disabled(controller.isCancelling)
                        .accessibilityIdentifier("update.cancel")
                }
            }
            if let message = controller.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let release = controller.availableRelease, let label = controller.openReleaseLabel {
                Button {
                    let url = release.downloadURL ?? release.url
                    if url.scheme == "https" { openURL(url) }
                } label: {
                    Label(label, systemImage: release.downloadURL == nil ? "safari" : "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityIdentifier("update.open")
            }
        }
        .onDisappear { controller.cancel() }
    }
}
