/* Coordinated app shutdown/relaunch. MDriveHealth, GPL-3.0-or-later. */
import AppKit
import Observation
import MDriveHealthCore

@MainActor @Observable final class ApplicationLifecycle {
    enum Kind: Sendable { case quit, relaunch }
    enum Phase { case running, stopping, waiting, saving, closing, launching, ready, failed(String) }
    private(set) var phase: Phase = .running
    private(set) var kind: Kind = .quit
    @ObservationIgnored var exitRequested: ((Kind) -> Void)?
    @ObservationIgnored private var preparing: Task<Bool, Never>?
    private let store: DriveStore
    private let monitor: MonitoringController
    private let benchmark: BenchmarkRunner
    private let capacity: CapacityVerifyRunner
    private let loginItems: LoginItemController?
    private let launch: @MainActor () async throws -> Void

    init(store: DriveStore, monitor: MonitoringController, benchmark: BenchmarkRunner, capacity: CapacityVerifyRunner,
         loginItems: LoginItemController? = nil,
         launch: @escaping @MainActor () async throws -> Void = ApplicationLifecycle.launchNewInstance) {
        self.store = store; self.monitor = monitor; self.benchmark = benchmark; self.capacity = capacity; self.launch = launch
        self.loginItems = loginItems
    }
    var isBusy: Bool {
        switch phase { case .stopping, .waiting, .saving, .closing, .launching: return true; default: return false }
    }
    var isReady: Bool { if case .ready = phase { return true }; return false }
    var failure: String? { if case .failed(let message) = phase { return message }; return nil }
    func requestRelaunch() { guard !isBusy else { return }; exitRequested?(.relaunch) }
    func retry() { guard failure != nil else { return }; exitRequested?(kind) }

    func begin(_ requestedKind: Kind) {
        guard !isBusy, !isReady else { return }
        kind = requestedKind; phase = .stopping
        store.beginShutdown(); monitor.beginShutdown(); benchmark.cancel(); capacity.cancel()
        loginItems?.beginShutdown()
    }

    func prepare(_ requestedKind: Kind) async -> Bool {
        if let preparing { return await preparing.value }
        if isReady { return true }
        begin(requestedKind)
        let requestedKind = kind
        let task = Task { @MainActor [self] in
            defer { preparing = nil }
            phase = .waiting
            async let monitoring: Void = monitor.shutdown()
            await benchmark.waitForCompletion(); await capacity.waitForCompletion()
            await store.operations.waitForIdle(); await store.waitForBackgroundWork()
            await loginItems?.waitForCompletion()
            await monitoring
            phase = .saving
            await benchmark.retrySaving(reconnect: !benchmark.unsavedResults.isEmpty)
            await capacity.retrySaving(reconnect: !capacity.unsavedResults.isEmpty)
            if !benchmark.unsavedResults.isEmpty || !capacity.unsavedResults.isEmpty {
                phase = .failed(String(localized: "lifecycle.unsaved", defaultValue: "Còn kết quả phép đo chưa lưu. App giữ lại kết quả và chưa thoát; thử lưu lại hoặc tiếp tục sử dụng."))
                return false
            }
            if benchmark.requiresWorkspaceReview || capacity.requiresWorkspaceReview {
                let ids = (benchmark.workspaceReviews + capacity.workspaceReviews).map { $0.id.uuidString }.joined(separator: "\n")
                phase = .failed(String(localized: "lifecycle.cleanupUnconfirmed", defaultValue: "Có phiên chưa xác nhận dọn file test. App chưa thoát; kiểm tra workspace của phiên trước khi thử lại.") + "\n" + ids)
                return false
            }
            do {
                phase = .closing; try await store.history.shutdown()
                if requestedKind == .relaunch { phase = .launching; try await launch() }
                phase = .ready; return true
            } catch {
                phase = .failed(error.localizedDescription); return false
            }
        }
        preparing = task
        return await task.value
    }
    func resume() async {
        guard failure != nil, preparing == nil else { return }
        do {
            try store.history.resumeAfterShutdown()
            store.resumeAfterShutdown(); phase = .running
            loginItems?.resumeAfterShutdown()
            await monitor.resumeAfterShutdown()
        } catch { phase = .failed(error.localizedDescription) }
    }
    private static func launchNewInstance() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        let application = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier, !application.isTerminated else {
            throw CocoaError(.executableNotLoadable)
        }
    }
}
