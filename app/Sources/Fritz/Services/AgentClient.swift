import Foundation
import Fritz

extension AgentClient {
    convenience init(bundle: Bundle = .main) {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "FRITZ_KEYCHAIN_SERVICE")
        if let directory = bundle.object(forInfoDictionaryKey: "FritzDataDirectory") as? String {
            environment["FRITZ_DATA_DIR"] = NSString(string: directory).expandingTildeInPath
        }
        if let service = bundle.object(forInfoDictionaryKey: "FritzKeychainService") as? String,
           !service.isEmpty {
            environment["FRITZ_KEYCHAIN_SERVICE"] = service
        }
        self.init(executableURL: bundle.resourceURL?.appendingPathComponent("fritz"), environment: environment)
    }
}

extension Encodable {
    public func jsonObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    }
}
