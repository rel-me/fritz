import Foundation

public enum AppUpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case release
    case beta
    case staging

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .release: "Release"
        case .beta: "Beta"
        case .staging: "Staging"
        }
    }

    public var allowedSparkleChannels: Set<String> {
        switch self {
        case .release: []
        case .beta: ["beta"]
        case .staging: ["beta", "staging"]
        }
    }
}
