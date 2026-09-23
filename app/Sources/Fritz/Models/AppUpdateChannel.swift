import Foundation

enum AppUpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case release
    case beta
    case dev

    var id: String { rawValue }

    var title: String {
        switch self {
        case .release: "Release"
        case .beta: "Beta"
        case .dev: "Dev"
        }
    }

    var allowedSparkleChannels: Set<String> {
        switch self {
        case .release: []
        case .beta: ["beta"]
        case .dev: ["beta", "dev"]
        }
    }

    static var saved: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "updateChannel") ?? "") ?? .release
    }
}
