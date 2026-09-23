import Foundation
import Observation
import Fritz
import FritzUpdates

@MainActor @Observable final class AppSettings {
    var appearance = AppAppearance.system.rawValue { didSet { save(appearance, key: "appearance") } }
    var updateChannel = AppUpdateChannel.release.rawValue { didSet { save(updateChannel, key: "updateChannel") } }
    var selectedTab = FritzSettingsTab.general.rawValue { didSet { save(selectedTab, key: "settingsTab") } }
    private(set) var error: String?
    private var canSave = true
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
        do {
            appearance = try database.setting("appearance") ?? AppAppearance.system.rawValue
            updateChannel = try database.setting("updateChannel") ?? AppUpdateChannel.release.rawValue
            selectedTab = try database.setting("settingsTab") ?? FritzSettingsTab.general.rawValue
        } catch {
            canSave = false
            self.error = "Could not restore settings: \(error.localizedDescription)"
        }
    }

    private func save(_ value: String, key: String) {
        guard canSave else { return }
        do { try database.set(value, for: key); error = nil }
        catch { self.error = "Could not save settings: \(error.localizedDescription)" }
    }
}
