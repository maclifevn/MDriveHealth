/* Signed application updates via Sparkle. MDriveHealth, GPL-3.0-or-later. */
import AppKit
import Combine
import Sparkle

@MainActor final class SparkleUpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false
    @Published private(set) var startupError: String?
    private var controller: SPUStandardUpdaterController!
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    var prepareInstallation: (@escaping () -> Void) -> Void

    init(prepareInstallation: @escaping (@escaping () -> Void) -> Void = { _ in }) {
        self.prepareInstallation = prepareInstallation
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] in self?.canCheckForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] in self?.automaticallyDownloadsUpdates = $0 }.store(in: &subscriptions)
        updater.publisher(for: \.allowsAutomaticUpdates).sink { [weak self] in self?.allowsAutomaticUpdates = $0 }.store(in: &subscriptions)
    }

    func start() {
        guard !started else { return }
        do {
            try Self.validateConfiguration(Bundle.main.infoDictionary ?? [:])
            try controller.updater.start()
            started = true; startupError = nil
        } catch { startupError = error.localizedDescription }
    }

    func checkForUpdates() {
        guard started, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Sparkle owns replacement/relaunch; our lifecycle drains workers and SQLite first.
        prepareInstallation(installHandler)
        return true
    }

    static func validateConfiguration(_ info: [String: Any]) throws {
        guard let feed = info["SUFeedURL"] as? String, let url = URLComponents(string: feed),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String, Data(base64Encoded: key)?.count == 32 else {
            throw NSError(domain: "com.maclife.MDriveHealth.updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "update.configurationError",
                              defaultValue: "Bản build này chưa có cấu hình cập nhật hợp lệ.")])
        }
    }
}
