@preconcurrency import Sparkle

/// Updates for the directly distributed app: Sparkle checks the signed appcast on
/// songtide.dcoded.dev once a day (Info.plist), downloads new versions quietly and installs them
/// when Songtide quits; "Check for Updates…" in the app menu checks right away. Once an update is
/// downloaded, the sidebar and the app menu offer to restart into it now (people who leave
/// Songtide open for days would otherwise wait until they next quit).
@MainActor @Observable
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    /// The version of a downloaded update waiting to be installed, if any.
    private(set) var readyVersion: String?
    /// A newer version found but not downloaded yet (e.g. "Remind Me Later" after checking).
    private(set) var availableVersion: String?
    /// Whether to offer an update at all (the sidebar card, the menus).
    var hasUpdate: Bool { readyVersion != nil || availableVersion != nil }
    @ObservationIgnored private var installNow: (() -> Void)?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Call once at launch so scheduled checks run.
    func start() {}

    func checkForUpdates() { controller.checkForUpdates(nil) }

    /// Installs the downloaded update and reopens Songtide, or, if it isn't downloaded yet, shows
    /// the update window to install it from.
    func installUpdate() {
        if let installNow { installNow() } else { checkForUpdates() }
    }

    /// Whether Songtide has checked for updates on this Mac before (so it isn't a new install).
    var hasCheckedBefore: Bool { controller.updater.lastUpdateCheckDate != nil }

    /// Checks daily, downloads in the background and installs when Songtide quits. Off: nothing
    /// happens until "Check for Updates…".
    var updatesAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates && controller.updater.automaticallyDownloadsUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    // MARK: SPUUpdaterDelegate

    /// A silently downloaded update is ready. Offer it (it still installs on quit if not taken).
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        nonisolated(unsafe) let install = immediateInstallationBlock
        MainActor.assumeIsolated {
            readyVersion = version
            installNow = install
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { availableVersion = version }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { availableVersion = nil }
    }

    /// "Skip This Version": stop offering it.
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                             forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        MainActor.assumeIsolated {
            availableVersion = nil
            readyVersion = nil
            installNow = nil
        }
    }
}
