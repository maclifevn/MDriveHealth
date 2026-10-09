/* Update preferences backed by Sparkle's own persisted settings. GPL-3.0-or-later. */
import SwiftUI

struct SparkleUpdateSettingsView: View {
    @ObservedObject var updater: SparkleUpdateController

    var body: some View {
        Toggle("update.automaticChecks", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates }, set: updater.setAutomaticChecks))
            .disabled(updater.startupError != nil)
            .accessibilityIdentifier("update.automaticChecks")
        Toggle("update.automaticDownloads", isOn: Binding(
            get: { updater.automaticallyDownloadsUpdates }, set: updater.setAutomaticDownloads))
            .disabled(!updater.allowsAutomaticUpdates || updater.startupError != nil)
            .accessibilityIdentifier("update.automaticDownloads")
        Text("update.automaticHelp").font(.caption).foregroundStyle(.secondary)
        Button("Kiểm tra bản cập nhật…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates || updater.startupError != nil)
            .accessibilityIdentifier("update.check")
        if let error = updater.startupError {
            Text(error).font(.caption).foregroundStyle(StatusPalette.caution.foreground)
        }
    }
}
