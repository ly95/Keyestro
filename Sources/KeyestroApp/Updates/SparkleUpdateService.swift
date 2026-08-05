import Combine
import Foundation
import KeyestroCore
import Sparkle

@MainActor
final class SparkleUpdateService: NSObject, ObservableObject, UpdateServicing, SPUUpdaterDelegate {
    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var channel = "stable"
    @Published private(set) var lastErrorMessage: String?

    private var controller: SPUStandardUpdaterController?
    private var observation: NSKeyValueObservation?
    private let defaults: UserDefaults
    private let channelKey = "updates.channel"

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
        channel = defaults.string(forKey: channelKey) == "beta" ? "beta" : "stable"
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let feedURL = URL(string: feed),
            feedURL.scheme?.lowercased() == "https",
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            lastErrorMessage = "This build has no signed update feed configured."
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        controller.startUpdater()
        isConfigured = true
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = controller.updater.automaticallyDownloadsUpdates
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }

    func setChannel(_ channel: String) {
        let normalized = channel == "beta" ? "beta" : "stable"
        self.channel = normalized
        defaults.set(normalized, forKey: channelKey)
        controller?.updater.resetUpdateCycleAfterShortDelay()
    }

    func checkForUpdates() {
        guard let controller else { return }
        controller.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == "beta" ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        if nsError.code != SUError.noUpdateError.rawValue,
            nsError.code != SUError.installationCanceledError.rawValue
        {
            lastErrorMessage = nsError.localizedDescription
        }
    }
}
