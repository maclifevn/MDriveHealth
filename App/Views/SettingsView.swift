/*
 * SettingsView.swift — app preferences.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI
import MDriveHealthCore

struct SettingsView: View {
    let history: HistoryAccess
    @ObservedObject var updater: SparkleUpdateController
    @Environment(MonitoringController.self) private var monitor
    @Environment(ApplicationLifecycle.self) private var lifecycle
    @Environment(LoginItemController.self) private var loginItems
    @AppStorage(SettingsKeys.pollIntervalMinutes) private var pollInterval = 5
    @AppStorage(SettingsKeys.alertTempThreshold) private var tempThreshold = 60
    @AppStorage(SettingsKeys.monitoringEnabled) private var monitoringEnabled = true
    @AppStorage(SettingsKeys.showMenuBar) private var showMenuBar = true
    @AppStorage(SettingsKeys.menuBarDisplay) private var menuBarDisplay = MenuBarDisplay.icon
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var languageNeedsRestart = false

    var body: some View {
        Form {
            Section("Theo dõi nền") {
                Toggle("Bật theo dõi & cảnh báo tự động", isOn: $monitoringEnabled)
                Picker("Chu kỳ đọc SMART", selection: $pollInterval) {
                    Text("1 phút").tag(1)
                    Text("5 phút").tag(5)
                    Text("10 phút").tag(10)
                    Text("30 phút").tag(30)
                    Text("60 phút").tag(60)
                }
                .disabled(!monitoringEnabled)
                Toggle("Cảnh báo khi quá nhiệt", isOn: Binding(
                    get: { tempThreshold > 0 },
                    set: { tempThreshold = $0 ? 60 : 0 }
                ))
                .disabled(!monitoringEnabled)
                if tempThreshold > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Ngưỡng cảnh báo nhiệt độ", value: "\(tempThreshold)°C")
                            .monospacedDigit()
                            .accessibilityHidden(true)
                        Slider(value: Binding(
                            get: { Double(tempThreshold) },
                            set: { tempThreshold = Int($0) }
                        ), in: 45...85, step: 5) {
                            Text("Ngưỡng cảnh báo nhiệt độ")
                        }
                        .labelsHidden()
                        .accessibilityValue(Text(verbatim: "\(tempThreshold)°C"))
                        .accessibilityIdentifier("settings.temperatureThreshold")
                    }
                    .accessibilityElement(children: .contain)
                    .disabled(!monitoringEnabled)
                }
                Text("monitor.alertPolicy")
                    .font(.caption).foregroundStyle(.secondary)
                if monitor.notificationAccess == .denied {
                    Text("monitor.notifications.denied")
                        .font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                }
                if let issue = monitor.authorizationError ?? monitor.deliveryError {
                    Text(issue).font(.caption).foregroundStyle(StatusPalette.caution.foreground)
                }
                if monitor.uncertainSelfTestNotifications > 0 {
                    Button("selftest.notification.dismissUncertain") {
                        Task { await monitor.dismissUncertainSelfTestNotifications() }
                    }
                }
                HStack {
                    Button("monitor.notifications.retry") {
                        Task { await monitor.retryNotifications() }
                    }
                    .disabled(!monitoringEnabled || monitor.isCheckingAuthorization)
                    if monitor.isCheckingAuthorization { ProgressView().controlSize(.small) }
                }
            }

            Section("Hệ thống") {
                Toggle("Hiện biểu tượng trên thanh menu", isOn: $showMenuBar)
                if showMenuBar {
                    Picker("Hiển thị cạnh biểu tượng", selection: $menuBarDisplay) {
                        ForEach(MenuBarDisplay.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }
                LoginItemControl(controller: loginItems)
                Picker("Ngôn ngữ / Language", selection: $appLanguage) {
                    Text("Theo hệ thống / System").tag("system")
                    Text("Tiếng Việt").tag("vi")
                    Text("English").tag("en")
                }
                .onChange(of: appLanguage) { _, choice in
                    applyLanguage(choice)
                }
                if languageNeedsRestart {
                    HStack {
                        Text("Khởi động lại app để áp dụng ngôn ngữ mới.")
                            .font(.caption)
                            .foregroundStyle(StatusPalette.caution.foreground)
                        Button("Khởi động lại ngay") { relaunchApp() }
                            .controlSize(.small)
                            .disabled(lifecycle.isBusy)
                    }
                }
            }

            if history.legacyCounts.total > 0 {
                Section("history.storage.title") {
                    LegacyHistoryNotice(access: history)
                }
            }

            Section("update.settings") {
                SparkleUpdateSettingsView(updater: updater)
            }

            Section {
                LabeledContent("Phiên bản", value: UpdateChecker.displayedVersion)
                LabeledContent("Drive database",
                               value: "smartmontools drivedb \(DriveDB.shared.version)")
                LabeledContent("Giấy phép", value: String(localized: "license.value",
                    defaultValue: "GPL-3.0-or-later — mã nguồn mở"))
                HStack {
                    Button("release.license") {
                        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .disabled(Bundle.main.url(forResource: "LICENSE", withExtension: nil) == nil)
                    Button("release.source") {
                        if let url = Bundle.main.url(forResource: "CorrespondingSource", withExtension: "zip") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .disabled(Bundle.main.url(forResource: "CorrespondingSource", withExtension: "zip") == nil)
                    .help("release.source.help")
                }
            } header: {
                Text("Về MDriveHealth")
            } footer: {
                // Markdown link renders clickable; "Maclife & Đồng Bọn" opens
                // the community Facebook group.
                Text("Made with ♥ for [Maclife & Đồng Bọn](https://www.facebook.com/groups/maclife.vn)")
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 400, idealHeight: 620, maxHeight: .infinity)
        .task { await monitor.refreshAuthorization() }
    }

    /// Standard per-app language override: set AppleLanguages and relaunch.
    private func applyLanguage(_ choice: String) {
        if choice == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([choice], forKey: "AppleLanguages")
        }
        languageNeedsRestart = true
    }

    private func relaunchApp() {
        lifecycle.requestRelaunch()
    }

}
