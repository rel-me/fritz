import Foundation
import Observation
import Fritz
import FritzUpdates

struct HarnessSettings: Codable, Equatable, Sendable {
    var automaticCompaction = true
    var contextTokens = 0
    var reserveTokens = 0
    var keepRecentTokens = 0
    var quantizeLocalKVCache: Bool?

    var requestParameters: [String: Any] {
        var parameters: [String: Any] = ["automaticCompaction": automaticCompaction]
        if quantizeLocalKVCache == true { parameters["quantizeLocalKVCache"] = true }
        if contextTokens > 0 { parameters["contextTokens"] = contextTokens }
        if reserveTokens > 0 { parameters["reserveTokens"] = reserveTokens }
        if keepRecentTokens > 0 { parameters["keepRecentTokens"] = keepRecentTokens }
        return parameters
    }
}

@MainActor @Observable final class AppSettings {
    var appearance = AppAppearance.system.rawValue { didSet { save(appearance, key: "appearance") } }
    var updateChannel = AppUpdateChannel.release.rawValue { didSet { save(updateChannel, key: "updateChannel") } }
    var selectedTab = FritzSettingsTab.general.rawValue { didSet { save(selectedTab, key: "settingsTab") } }
    var harness = HarnessSettings() { didSet { save(harness, key: "harness") } }
    private(set) var error: String?
    private var canSave = true
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
        do {
            appearance = try database.setting("appearance") ?? AppAppearance.system.rawValue
            updateChannel = try database.setting("updateChannel") ?? AppUpdateChannel.release.rawValue
            // Preserve the selected channel when upgrading from the Dev name.
            if updateChannel == "dev" {
                updateChannel = AppUpdateChannel.staging.rawValue
                try database.set(updateChannel, for: "updateChannel")
            }
            selectedTab = try database.setting("settingsTab") ?? FritzSettingsTab.general.rawValue
            harness = try database.setting("harness") ?? HarnessSettings()
        } catch {
            canSave = false
            self.error = "Could not restore settings: \(error.localizedDescription)"
        }
    }

    private func save(_ value: some Encodable, key: String) {
        guard canSave else { return }
        do { try database.set(value, for: key); error = nil }
        catch { self.error = "Could not save settings: \(error.localizedDescription)" }
    }
}
