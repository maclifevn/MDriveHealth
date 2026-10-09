/* Tracked manual checks with cancellation and explicit retry. GPL-3.0-or-later. */
import Foundation
import Observation

@MainActor @Observable final class UpdateCheckController {
    private(set) var isBusy = false
    private(set) var isCancelling = false
    private(set) var result: UpdateChecker.CheckResult?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let operation: @Sendable () async -> UpdateChecker.CheckResult
    init(operation: @escaping @Sendable () async -> UpdateChecker.CheckResult = { await UpdateChecker.checkForUpdate() }) { self.operation = operation }
    func check() {
        guard !isBusy else { return }
        isBusy = true; isCancelling = false; result = nil
        task = Task { [weak self, operation] in
            let result = await operation()
            guard let self else { return }
            self.result = Task.isCancelled ? .cancelled : result
            self.isBusy = false; self.isCancelling = false; self.task = nil
        }
    }
    func cancel() {
        guard isBusy else { return }
        isCancelling = true; task?.cancel()
    }
    func waitForCompletion() async { await task?.value }
    var availableRelease: UpdateChecker.Release? { if case .available(let release) = result { return release }; return nil }
    var statusMessage: String? {
        switch result {
        case .available(let release): return String.localizedStringWithFormat(String(localized: "update.available", defaultValue: "Version %@ is available!"), release.version)
        case .upToDate: return String(localized: "update.latest", defaultValue: "You're on the latest version.")
        case .cancelled: return String(localized: "update.cancelled", defaultValue: "Update check cancelled.")
        case .failed(let failure): return String.localizedStringWithFormat(String(localized: "update.failed", defaultValue: "Could not check: %@"), failure.message)
        case nil: return nil
        }
    }
    var openReleaseLabel: String? {
        guard let release = availableRelease else { return nil }
        return release.downloadURL == nil
            ? String.localizedStringWithFormat(String(localized: "update.openRelease", defaultValue: "View release %@"), release.version)
            : String.localizedStringWithFormat(String(localized: "update.download", defaultValue: "Download %@"), release.version)
    }
}
