import Foundation

enum BundledModelCatalog {
    private static let data = Result {
        guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else {
            throw URLError(.fileDoesNotExist)
        }
        return try Data(contentsOf: url)
    }

    static func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: data.get())
    }

    private struct Decision: Decodable { let id: String }
    private struct Decisions: Decodable { let remote_decision: [String: Decision] }

    private static let decisions: [String: Decision] = {
        guard let catalog = try? decode(Decisions.self) else {
            preconditionFailure("Missing or invalid bundled remote decision catalog")
        }
        return catalog.remote_decision
    }()

    static func decisionModelID(for provider: AIProviderKind) -> String {
        guard let decision = decisions[provider.rawValue], !decision.id.isEmpty else {
            preconditionFailure("Missing bundled decision model for \(provider.rawValue)")
        }
        return decision.id
    }
}
