/* Notification delivery boundary. MDriveHealth, GPL-3.0-or-later. */
import Foundation
import UserNotifications

enum NotificationAccess: Equatable { case notDetermined, allowed, denied }
struct DriveAlert: Identifiable, Equatable {
    let id: String
    let title: String
    let body: String
    let driveKey: String
    let category: String
    let backupDate: Date?
}

@MainActor protocol NotificationDelivering {
    func access() async -> NotificationAccess
    func requestPermission() async throws -> Bool
    func send(_ alert: DriveAlert) async throws
    func registeredRequestIDs() async -> Set<String>
}
extension NotificationDelivering {
    func registeredRequestIDs() async -> Set<String> { [] }
}

struct SystemNotificationDelivery: NotificationDelivering {
    func access() async -> NotificationAccess {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .denied: return .denied
        default: return .notDetermined
        }
    }
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }
    func send(_ alert: DriveAlert) async throws {
        let content = UNMutableNotificationContent()
        content.title = alert.title; content.body = alert.body; content.sound = .default
        content.userInfo = ["driveIdentityKey": alert.driveKey]
        try await UNUserNotificationCenter.current().add(.init(identifier: alert.id, content: content, trigger: nil))
    }
    func registeredRequestIDs() async -> Set<String> {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        return Set(pending.map(\.identifier) + delivered.map { $0.request.identifier })
    }
}
