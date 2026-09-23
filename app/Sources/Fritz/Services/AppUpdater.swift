import Combine
import Foundation
import Sparkle
import SwiftUI

struct AppUpdateConfiguration: Equatable {
    let feedURL: URL?
    let publicEDKey: String?

    init(infoDictionary: [String: Any]?) {
        let feedURLString = infoDictionary?["SUFeedURL"] as? String
        let publicEDKey = infoDictionary?["SUPublicEDKey"] as? String

        if let feedURLString,
           let feedURL = URL(string: feedURLString),
           feedURL.scheme?.lowercased() == "https"
        {
            self.feedURL = feedURL
        } else {
            feedURL = nil
        }

        if let publicEDKey {
            let trimmedKey = publicEDKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if Data(base64Encoded: trimmedKey)?.count == 32 {
                self.publicEDKey = trimmedKey
            } else {
                self.publicEDKey = nil
            }
        } else {
            self.publicEDKey = nil
        }
    }

    var isConfigured: Bool {
        feedURL != nil && publicEDKey != nil
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var startupState: AppUpdateStartupState

    let isConfigured: Bool
    private(set) var updateChannel: AppUpdateChannel
    private var controller: SPUStandardUpdaterController?

    init(bundle: Bundle = .main, updateChannel: AppUpdateChannel = .release) {
        let configuration = AppUpdateConfiguration(infoDictionary: bundle.infoDictionary)
        isConfigured = configuration.isConfigured
        self.updateChannel = updateChannel
        startupState = configuration.isConfigured ? .pending : .notConfigured
        super.init()

        // Keep Sparkle's windows top-level so its cancellation and modal teardown
        // retain their native lifecycle.
        let controller = SPUStandardUpdaterController(
            startingUpdater: configuration.isConfigured,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller

        if configuration.isConfigured {
            controller.updater.publisher(for: \.canCheckForUpdates)
                .assign(to: &$canCheckForUpdates)
        }
    }

    var hasCompletedStartupCheck: Bool {
        startupState.hasCompletedCheck
    }

    var allowsAppUse: Bool {
        startupState.allowsAppUse
    }

    var requiredVersion: String? {
        startupState.requiredVersion
    }

    func checkForUpdatesAtStartup() {
        guard isConfigured, startupState == .pending, let controller else {
            return
        }

        startupState = .checking
        controller.updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    func setUpdateChannel(_ updateChannel: AppUpdateChannel) {
        guard self.updateChannel != updateChannel else {
            return
        }
        self.updateChannel = updateChannel
        controller?.updater.resetUpdateCycle()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannel.allowedSparkleChannels
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        startupState = .available(
            version: item.displayVersionString,
            requiresUpgrade: item.isCriticalUpdate
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard startupState == .checking else {
            return
        }
        startupState = .current
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        guard startupState == .checking else {
            return
        }
        startupState = error == nil ? .current : .failed
    }
}

struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        if updater.isConfigured {
            Button("Check for Updates") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
