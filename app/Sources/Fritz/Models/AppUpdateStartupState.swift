enum AppUpdateStartupState: Equatable {
    case notConfigured
    case pending
    case checking
    case current
    case available(version: String, requiresUpgrade: Bool)
    case failed

    var hasCompletedCheck: Bool {
        switch self {
        case .pending, .checking:
            false
        case .notConfigured, .current, .available, .failed:
            true
        }
    }

    var allowsAppUse: Bool {
        switch self {
        case .pending, .checking:
            false
        case .available(_, let requiresUpgrade):
            !requiresUpgrade
        case .notConfigured, .current, .failed:
            true
        }
    }

    var requiredVersion: String? {
        guard case .available(let version, requiresUpgrade: true) = self else {
            return nil
        }
        return version
    }
}
