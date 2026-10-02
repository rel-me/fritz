import Foundation

/// Non-secret references for a one-time import from a host's previous storage.
public struct ProviderMigrationItem: Codable, Sendable {
    public struct CredentialSource: Codable, Sendable {
        public let service: String
        public let account: UUID
        public init(service: String, account: UUID) { self.service = service; self.account = account }
    }
    public let connection: ProviderConnection
    public let credentialSource: CredentialSource?
    public init(connection: ProviderConnection, credentialSource: CredentialSource? = nil) {
        self.connection = connection; self.credentialSource = credentialSource
    }
}

public struct ProviderMigration: Codable, Sendable {
    public let migrationID: String
    public let providers: [ProviderMigrationItem]
    public let defaultConnectionID: UUID?
    public init(id: String, providers: [ProviderMigrationItem], defaultConnectionID: UUID?) {
        migrationID = id; self.providers = providers; self.defaultConnectionID = defaultConnectionID
    }
    private enum CodingKeys: String, CodingKey {
        case migrationID = "migrationId", providers, defaultConnectionID = "defaultConnectionId"
    }
}

public struct ProviderMigrationResult: Codable, Sendable {
    /// Original connection UUIDs map to the destination UUIDs, including deduplicated endpoints.
    public let connectionIDs: [String: UUID]
    private enum CodingKeys: String, CodingKey { case connectionIDs = "connectionIds" }
}
