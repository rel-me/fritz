import Combine
import Foundation
import Sparkle
import SwiftUI

public struct AppUpdateConfiguration: Equatable {
    public let feedURL: URL?
    public let publicEDKey: String?

    public init(infoDictionary: [String: Any]?) {
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

    public var isConfigured: Bool {
        feedURL != nil && publicEDKey != nil
    }
}

@MainActor
public final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published public private(set) var canCheckForUpdates = false
    @Published public private(set) var startupState: AppUpdateStartupState

    public let isConfigured: Bool
    public private(set) var updateChannel: AppUpdateChannel
    private var controller: SPUStandardUpdaterController?

    public init(bundle: Bundle = .main, updateChannel: AppUpdateChannel = .release) {
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

    public var hasCompletedStartupCheck: Bool {
        startupState.hasCompletedCheck
    }

    public var allowsAppUse: Bool {
        startupState.allowsAppUse
    }

    public var requiredVersion: String? {
        startupState.requiredVersion
    }

    public func checkForUpdatesAtStartup() {
        guard isConfigured, startupState == .pending, let controller else {
            return
        }

        startupState = .checking
        controller.updater.checkForUpdatesInBackground()
    }

    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    public func setUpdateChannel(_ updateChannel: AppUpdateChannel) {
        guard self.updateChannel != updateChannel else {
            return
        }
        self.updateChannel = updateChannel
        controller?.updater.resetUpdateCycle()
    }

    public func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannel.allowedSparkleChannels
    }

    public func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        startupState = .available(
            version: item.displayVersionString,
            requiresUpgrade: item.isCriticalUpdate
        )
    }

    public func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        guard startupState == .checking else {
            return
        }
        startupState = .current
    }

    public func updater(
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

public struct CheckForUpdatesCommand: View {
    @ObservedObject private var updater: AppUpdater

    public init(updater: AppUpdater) {
        self.updater = updater
    }

    public var body: some View {
        if updater.isConfigured {
            Button("Check for Updates") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
