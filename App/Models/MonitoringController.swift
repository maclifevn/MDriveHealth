/*
 * MonitoringController.swift — background polling + degradation alerts.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import Foundation
import Observation
import UserNotifications
import MDriveHealthCore

private final class PreferenceObservation {
    let token: any NSObjectProtocol
    init(_ token: any NSObjectProtocol) { self.token = token }
    deinit { NotificationCenter.default.removeObserver(token) }
}

enum SettingsKeys {
    static let pollIntervalMinutes = "pollIntervalMinutes"   // Int, default 5
    static let alertTempThreshold = "alertTempThreshold"     // Int °C, default 60; 0 = off
    static let monitoringEnabled = "monitoringEnabled"       // Bool, default true
    static let showMenuBar = "showMenuBar"                   // Bool, default true
    static let menuBarDisplay = "menuBarDisplay"             // "icon" | "temp" | "score"
    static let backupReminderPrefix = "backupReminder."
    static let selfTestSuppressedThrough = "selfTestSuppressedThrough" // Date: explicit monitoring-off boundary
    static let selfTestNotificationsWereDisabled = "selfTestNotificationsWereDisabled"

    static func registerDefaults(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            pollIntervalMinutes: 5,
            alertTempThreshold: 60,
            monitoringEnabled: true,
            showMenuBar: true,
            menuBarDisplay: "icon",
        ])
    }
}

@MainActor
@Observable
final class MonitoringController {
    private let store: DriveStore
    private let defaults: UserDefaults
    private let delivery: any NotificationDelivering
    private let now: @MainActor () -> Date
    private let observesPreferences: Bool
    private var timer: Timer?
    @ObservationIgnored private var defaultsObserver: PreferenceObservation?
    private var hasStarted = false
    private var isSuspended = false
    @ObservationIgnored private var activeDrains = 0
    @ObservationIgnored private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var enabledAt: Date?
    private var configuration: Configuration?
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    private var reevaluate = false
    @ObservationIgnored private var authorizationTask: Task<Void, Never>?
    private var authorizationRequested = false
    private var alertedState: [String: AlertState] = [:]
    private(set) var notificationAccess: NotificationAccess?
    private(set) var authorizationError: String?
    private(set) var deliveryError: String?
    private(set) var pendingAlerts: [DriveAlert] = []
    private(set) var isCheckingAuthorization = false
    private(set) var uncertainSelfTestNotifications = 0
    var scheduledIntervalMinutes: Int? { timer.map { Int($0.timeInterval / 60) } }

    private struct Configuration: Equatable {
        let enabled: Bool
        let minutes: Int
        let threshold: Int
    }
    private struct AlertState {
        var capturedAt: Date
        var rating: HealthRating
        var defects: UInt64?
        var overTemp: Bool?
        var threshold: Int
    }
    private var preferences: Configuration {
        let rawThreshold = defaults.integer(forKey: SettingsKeys.alertTempThreshold)
        return .init(enabled: defaults.bool(forKey: SettingsKeys.monitoringEnabled),
                     minutes: min(60, max(1, defaults.integer(forKey: SettingsKeys.pollIntervalMinutes))),
                     threshold: rawThreshold > 0 ? min(85, max(45, rawThreshold)) : 0)
    }

    init(store: DriveStore, defaults: UserDefaults = .standard,
         delivery: (any NotificationDelivering)? = nil,
         now: @escaping @MainActor () -> Date = Date.init, observePreferences: Bool = true) {
        self.store = store; self.defaults = defaults; self.delivery = delivery ?? SystemNotificationDelivery(); self.now = now
        self.observesPreferences = observePreferences
        SettingsKeys.registerDefaults(in: defaults)
        store.onFreshFleet = { [weak self] in
            Task { @MainActor [weak self] in await self?.evaluateAlerts() }
        }
    }
    private func observeDefaultsIfNeeded() {
        if observesPreferences, defaultsObserver == nil {
            defaultsObserver = PreferenceObservation(NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.preferencesChanged() }
            })
        }
    }

    /// Reopening a window does not reset the timer or request permission again.
    func start() async {
        guard !hasStarted, !isSuspended, !store.operations.isShuttingDown else { return }
        hasStarted = true
        observeDefaultsIfNeeded()
        preferencesChanged(refresh: false)
        if preferences.enabled { await refreshAuthorization(requestIfNeeded: true) }
    }
    func stop() {
        timer?.invalidate(); timer = nil; hasStarted = false
        configuration = nil
        enabledAt = nil; pendingAlerts.removeAll(); alertedState.removeAll()
        evaluationTask?.cancel(); authorizationTask?.cancel()
        defaultsObserver = nil
    }
    func shutdown() async {
        let evaluation = evaluationTask, authorization = authorizationTask
        beginShutdown()
        await evaluation?.value; await authorization?.value
        if activeDrains > 0 { await withCheckedContinuation { drainWaiters.append($0) } }
    }
    func beginShutdown() { isSuspended = true; stop() }
    func resumeAfterShutdown() async { isSuspended = false; await start() }
    func preferencesChanged(refresh: Bool = true) {
        guard hasStarted else { return }
        let current = preferences, previous = configuration
        guard current != previous else { return }
        configuration = current
        if !current.enabled {
            timer?.invalidate(); timer = nil; enabledAt = nil
            alertedState.removeAll(); pendingAlerts.removeAll(); deliveryError = nil
            defaults.set(now(), forKey: SettingsKeys.selfTestSuppressedThrough)
            defaults.set(true, forKey: SettingsKeys.selfTestNotificationsWereDisabled)
            Task { [weak self] in await self?.drainSelfTestEvents(suppressOnly: true) }
            return
        }
        if previous?.enabled != true {
            enabledAt = now(); alertedState.removeAll(); pendingAlerts.removeAll()
            if defaults.bool(forKey: SettingsKeys.selfTestNotificationsWereDisabled) {
                defaults.set(now(), forKey: SettingsKeys.selfTestSuppressedThrough)
                defaults.set(false, forKey: SettingsKeys.selfTestNotificationsWereDisabled)
            }
        }
        if hasStarted, timer == nil || previous?.minutes != current.minutes { scheduleTimer(minutes: current.minutes) }
        if refresh, hasStarted, previous?.enabled != true || previous?.threshold != current.threshold {
            Task { [weak self] in
                guard let self, self.hasStarted, self.preferences.enabled else { return }
                await self.refreshAuthorization(requestIfNeeded: true)
                guard self.hasStarted, !Task.isCancelled else { return }
                if !self.preferences.enabled { await self.drainSelfTestEvents(suppressOnly: true); return }
                await self.store.refresh(wakingSleepingDrives: false)
            }
        }
    }
    private func scheduleTimer(minutes: Int) {
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            Task { @MainActor [weak self] in await self?.tick() }
        }
        timer.tolerance = 30; RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func tick() async {
        preferencesChanged(refresh: false)
        guard hasStarted, preferences.enabled else { return }
        await store.refresh(wakingSleepingDrives: false)
        await evaluateAlerts()
    }

    /// Called by every completed fleet refresh, including manual refreshes.
    /// Only successful, non-sleeping readings captured during this enabled
    /// session and at most two minutes old can create a new event.
    func evaluateAlerts() async {
        guard hasStarted else { return }
        if let evaluationTask { reevaluate = true; await evaluationTask.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.evaluationTask = nil }
            repeat {
                self.reevaluate = false; self.preferencesChanged(refresh: false)
                guard self.hasStarted, !Task.isCancelled else { return }
                if !self.preferences.enabled { await self.drainSelfTestEvents(suppressOnly: true); return }
                if !self.store.isRefreshing, self.store.refreshError == nil { self.collectAlerts() }
                await self.refreshAuthorization(requestIfNeeded: true)
                self.preferencesChanged(refresh: false)
                guard self.hasStarted, self.preferences.enabled, !Task.isCancelled else { return }
                if self.notificationAccess == .allowed { await self.drainAlerts() }
                await self.drainSelfTestEvents()
            } while self.reevaluate && !Task.isCancelled
        }
        evaluationTask = task
        await task.value
    }

    private func collectAlerts() {
        guard let enabledAt else { return }
        let stamp = now(), threshold = preferences.threshold
        let currentKeys = Set(store.snapshots.map { $0.identity.key })
        alertedState = alertedState.filter { currentKeys.contains($0.key) }
        for snapshot in store.snapshots {
            guard !snapshot.isStale, !snapshot.skippedWhileSleeping, !snapshot.isProbing,
                  snapshot.lastError == nil, let reading = snapshot.reading, let health = snapshot.health,
                  snapshot.lastUpdated == reading.capturedAt,
                  reading.capturedAt >= enabledAt, reading.capturedAt <= stamp,
                  stamp.timeIntervalSince(reading.capturedAt) <= 120 else { continue }
            let key = snapshot.identity.key, model = snapshot.drive.model
            let previous = alertedState[key]
            guard previous == nil || reading.capturedAt > previous!.capturedAt else { continue }
            let defects = reading.dangerousDefectTotal
            let overTemp = reading.temperatureCelsius.map { threshold > 0 && $0 >= threshold }
            var alerts: [DriveAlert] = []
            func append(_ category: String, _ title: String, _ body: String, backupDate: Date? = nil) {
                alerts.append(.init(id: UUID().uuidString, title: title, body: body, driveKey: key,
                                    category: category, backupDate: backupDate))
            }
            if let previous, previous.rating != .unknown, health.rating > previous.rating, health.rating >= .warning {
                append("degraded", String(localized: "notify.degraded.title", defaultValue: "Sức khoẻ ổ đĩa giảm: \(model)"),
                       String(localized: "notify.degraded.body", defaultValue: "Tình trạng chuyển từ “\(previous.rating.displayName)” xuống “\(health.rating.displayName)” (\(health.scoreDisplay)/100). Hãy sao lưu dữ liệu và kiểm tra chi tiết trong MDriveHealth."))
            } else if previous == nil || previous?.rating == .unknown, health.rating >= .failing {
                append("failing", String(localized: "notify.failing.title", defaultValue: "Ổ đĩa đang hỏng: \(model)"),
                       String(localized: "notify.failing.body", defaultValue: "Tình trạng: \(health.rating.displayName) (\(health.scoreDisplay)/100). Sao lưu dữ liệu ngay lập tức!"))
            }
            let baselineDefects = previous?.defects ?? snapshot.previousHistory.flatMap { ATAMetrics.checkedSum([$0.defectCount, $0.pendingSectors]) }
            if let defects, let baselineDefects, defects > baselineDefects {
                append("defects", String(localized: "notify.defects.title", defaultValue: "Phát hiện lỗi mới: \(model)"),
                       String(localized: "notify.defects.body", defaultValue: "Số sector lỗi/media error tăng từ \(Int(clamping: baselineDefects)) lên \(Int(clamping: defects)). Đây là dấu hiệu bề mặt lưu trữ đang xuống cấp."))
            }
            // A new threshold starts a temperature baseline at the next fresh
            // reading. An already-hot first reading is not silently consumed.
            if overTemp == true, previous?.overTemp != true || previous?.threshold != threshold {
                append("temperature", String(localized: "notify.temp.title", defaultValue: "Nhiệt độ cao: \(model)"),
                       String(localized: "notify.temp.body", defaultValue: "Ổ đĩa đạt \(reading.temperatureCelsius ?? 0)°C, vượt ngưỡng cảnh báo \(threshold)°C."))
            }
            let reminderKey = SettingsKeys.backupReminderPrefix + key
            let lastReminder = defaults.object(forKey: reminderKey) as? Date
            let reminderPending = pendingAlerts.contains { $0.driveKey == key && $0.category == "backup" }
            if health.rating >= .warning, !reminderPending,
               lastReminder == nil || stamp.timeIntervalSince(lastReminder!) >= 86_400 {
                append("backup", String(localized: "notify.backup.title", defaultValue: "Backup reminder: \(model)"),
                       String(localized: "notify.backup.body", defaultValue: "The drive is at \(health.rating.displayName). Confirm your latest backup is usable before writing more important data."), backupDate: stamp)
            }
            guard pendingAlerts.count + alerts.count <= 4096 else {
                deliveryError = String(localized: "monitor.notifications.queueFull", defaultValue: "Quá nhiều cảnh báo chưa gửi. Hãy thử gửi lại thông báo.")
                continue // Do not advance a baseline for events we could not retain.
            }
            pendingAlerts.append(contentsOf: alerts)
            alertedState[key] = .init(capturedAt: reading.capturedAt,
                                     rating: health.rating == .unknown ? (previous?.rating ?? .unknown) : health.rating,
                                     defects: defects ?? previous?.defects,
                                     overTemp: overTemp ?? (previous?.threshold == threshold ? previous?.overTemp : nil), threshold: threshold)
        }
    }

    func refreshAuthorization(requestIfNeeded: Bool = false) async {
        guard !isSuspended else { return }
        authorizationRequested = authorizationRequested || requestIfNeeded
        if let authorizationTask { await authorizationTask.value; return }
        isCheckingAuthorization = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isCheckingAuthorization = false; self.authorizationRequested = false; self.authorizationTask = nil }
            self.notificationAccess = await self.delivery.access()
            if self.authorizationRequested, self.hasStarted, self.preferences.enabled, !Task.isCancelled, self.notificationAccess == .notDetermined {
                do {
                    _ = try await self.delivery.requestPermission()
                    self.notificationAccess = await self.delivery.access(); self.authorizationError = nil
                } catch { self.authorizationError = error.localizedDescription }
            } else if self.notificationAccess != .notDetermined { self.authorizationError = nil }
        }
        authorizationTask = task
        await task.value
    }
    func retryNotifications() async { await evaluateAlerts() }
    func dismissUncertainSelfTestNotifications() async { await drainSelfTestEvents(dismissUncertain: true) }
    private func drainAlerts() async {
        while hasStarted, preferences.enabled, !Task.isCancelled, let alert = pendingAlerts.first {
            do {
                try await delivery.send(alert)
                pendingAlerts.removeAll { $0.id == alert.id }
                if alert.backupDate != nil { defaults.set(now(), forKey: SettingsKeys.backupReminderPrefix + alert.driveKey) }
            } catch { deliveryError = error.localizedDescription; return }
        }
        deliveryError = nil
    }
    private func selfTestAlert(_ event: SelfTestCompletion) -> DriveAlert {
        let body: String
        switch event.outcome {
        case .passed: body = String(localized: "notify.selftest.passed", defaultValue: "Kết quả: ĐẠT — không phát hiện lỗi trong lần tự kiểm tra này.")
        case .failed: body = String(localized: "notify.selftest.failed", defaultValue: "Kết quả: CÓ VẤN ĐỀ — mở tab Self-test để xem chi tiết và sao lưu dữ liệu sớm.")
        case .aborted: body = String(localized: "notify.selftest.aborted", defaultValue: "Lần tự kiểm tra đã bị hủy hoặc gián đoạn; chưa có kết quả kiểm tra đầy đủ.")
        case .indeterminate: body = String(localized: "notify.selftest.indeterminate", defaultValue: "Chưa xác định được kết quả của lần tự kiểm tra; kiểm tra nhật ký trong tab Self-test.")
        }
        return .init(id: "self-test." + event.id.uuidString, title: String(localized: "notify.selftest.title", defaultValue: "Self-test hoàn tất: \(event.model)"),
                     body: body, driveKey: event.driveKey, category: "selfTest", backupDate: nil)
    }
    /// A separate private lock serializes reconciliation and SDK submission
    /// across app instances. A crash after claim never silently resends.
    private func drainSelfTestEvents(suppressOnly: Bool = false, dismissUncertain: Bool = false) async {
        guard !isSuspended, store.history.state == .ready else { return }
        activeDrains += 1
        defer {
            activeDrains -= 1
            if activeDrains == 0 { let waiters = drainWaiters; drainWaiters.removeAll(); for waiter in waiters { waiter.resume() } }
        }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mdrivehealth-notification-locks-v1")
            let lock: DriveCommandLock.Lease
            do { lock = try await DriveCommandLock.acquireAsync(registryEntryID: 1, directory: directory) }
            catch DriveCommandLockError.busy { return }
            defer { lock.release() }
            let stored = try await store.history.run("selfTest.outbox") {
                try await $0.selfTestEvents(states: [.pending, .sending, .uncertain])
            }
            let needsReconciliation = stored.contains { $0.delivery == .sending || $0.delivery == .uncertain }
            let registered = needsReconciliation && !suppressOnly ? await delivery.registeredRequestIDs() : []
            uncertainSelfTestNotifications = 0
            let suppressedThrough = defaults.object(forKey: SettingsKeys.selfTestSuppressedThrough) as? Date
            for row in stored {
                let event = row.event, alert = selfTestAlert(event)
                func transition(_ from: SelfTestDeliveryState, _ to: SelfTestDeliveryState) async throws -> Bool {
                    try await store.history.run("selfTest.delivery:" + event.id.uuidString) {
                        try await $0.transitionSelfTestEvent(id: event.id, from: from, to: to)
                    }
                }
                if !preferences.enabled || suppressedThrough.map({ event.createdAt <= $0 }) == true {
                    _ = try await transition(row.delivery, .suppressed); continue
                }
                if suppressOnly { continue }
                if dismissUncertain {
                    if row.delivery != .pending { _ = try await transition(row.delivery, .suppressed) }
                    continue
                }
                guard hasStarted, !Task.isCancelled else { return }
                if row.delivery != .pending {
                    if registered.contains(alert.id) { _ = try await transition(row.delivery, .delivered) }
                    else {
                        if row.delivery == .sending { _ = try await transition(.sending, .uncertain) }
                        uncertainSelfTestNotifications += 1
                    }
                    continue
                }
                guard notificationAccess == .allowed else { continue }
                guard try await transition(.pending, .sending) else { continue }
                guard hasStarted, preferences.enabled, !Task.isCancelled else {
                    _ = try await transition(.sending, preferences.enabled ? .pending : .suppressed); return
                }
                do { try await delivery.send(alert) }
                catch {
                    _ = try await transition(.sending, .pending)
                    deliveryError = error.localizedDescription; return
                }
                _ = try await transition(.sending, .delivered)
            }
            if uncertainSelfTestNotifications > 0 {
                deliveryError = String(localized: "selftest.notification.uncertain", defaultValue: "Có \(uncertainSelfTestNotifications) thông báo self-test chưa xác nhận đã hiển thị. Kết quả vẫn được lưu; app không tự gửi lại để tránh thông báo trùng.")
            }
            if dismissUncertain { deliveryError = nil }
        } catch { deliveryError = error.localizedDescription }
    }
}
