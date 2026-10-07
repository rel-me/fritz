import Foundation

@MainActor public protocol ModelsPreferences: AnyObject {
    func setting<T: Decodable>(_ key: String, as: T.Type) throws -> T?
    func set<T: Encodable>(_ value: T, for key: String) throws
}

extension ModelsPreferences {
    func setting<T: Decodable>(_ key: String) throws -> T? { try setting(key, as: T.self) }
}
