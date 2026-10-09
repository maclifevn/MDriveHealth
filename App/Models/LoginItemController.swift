/* Shared login-item state and owned SDK mutation. GPL-3.0-or-later. */
import Foundation
import Observation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound, unknown
    var isRequested: Bool { self == .enabled || self == .requiresApproval }
    var canChange: Bool { self != .notFound && self != .unknown }
    var message: String {
        switch self {
        case .notRegistered: return String(localized: "login.status.off", defaultValue: "Chưa đăng ký tự chạy khi đăng nhập.")
        case .enabled: return String(localized: "login.status.enabled", defaultValue: "Đã đăng ký và được macOS cho phép tự chạy khi đăng nhập.")
        case .requiresApproval: return String(localized: "login.status.approval", defaultValue: "Đã đăng ký nhưng chưa được macOS cho phép chạy. Mở Cài đặt hệ thống để cho phép MDriveHealth trong Mục đăng nhập.")
        case .notFound: return String(localized: "login.status.notFound", defaultValue: "macOS không tìm thấy login item của app. Thử mở lại app từ vị trí đã cài đặt, rồi kiểm tra lại.")
        case .unknown: return String(localized: "login.status.unknown", defaultValue: "Chưa xác định được trạng thái login item. Kiểm tra lại trước khi thay đổi.")
        }
    }
}

@MainActor protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) async throws
    func openSettings()
}

@MainActor final class SystemLoginItems: LoginItemManaging {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    func setEnabled(_ enabled: Bool) async throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try await SMAppService.mainApp.unregister() }
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor @Observable final class LoginItemController {
    private(set) var status: LoginItemStatus
    private(set) var isBusy = false
    private(set) var isShuttingDown = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any LoginItemManaging
    @ObservationIgnored private var task: Task<Void, Never>?

    init(service: (any LoginItemManaging)? = nil) {
        let service = service ?? SystemLoginItems()
        self.service = service; status = service.status
    }
    var canChange: Bool { status.canChange && !isBusy && !isShuttingDown }
    func refresh() {
        guard !isBusy else { return }
        let fresh = service.status
        if fresh != status { errorMessage = nil }
        status = fresh
    }
    func setRequested(_ enabled: Bool) {
        guard !isBusy, !isShuttingDown else { return }
        refresh()
        guard status.canChange else { return }
        guard enabled != status.isRequested else { errorMessage = nil; return }
        isBusy = true; errorMessage = nil
        // Closing a view does not cancel an SDK mutation already accepted.
        // The app owns this task; coordinated quit waits for its completion.
        task = Task { @MainActor [self] in
            defer { isBusy = false; task = nil }
            var failure: Error?
            do { try await service.setEnabled(enabled) }
            catch { failure = error }
            status = service.status
            if enabled ? status == .enabled : status == .notRegistered { return }
            if let failure {
                errorMessage = String.localizedStringWithFormat(String(localized: "login.error", defaultValue: "Không đổi được login item: %@"), failure.localizedDescription)
            } else if !(enabled && status == .requiresApproval) {
                errorMessage = String(localized: "login.changeUnconfirmed", defaultValue: "macOS chưa xác nhận thay đổi login item. Kiểm tra trạng thái và thử lại.")
            }
        }
    }
    func openSettings() { guard !isBusy, !isShuttingDown else { return }; service.openSettings() }
    func waitForCompletion() async { await task?.value }
    func beginShutdown() { isShuttingDown = true }
    func resumeAfterShutdown() { isShuttingDown = false; refresh() }
}
