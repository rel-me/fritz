import Fritz
import Foundation
import FritzUI

typealias ProviderStore = ModelsStore

extension ModelsStore {
    convenience init(agent: AgentClient, database: AppDatabase, modelCatalog: RemoteModelCatalog? = nil) {
        self.init(agent: agent, preferences: database, keychainService:
            Bundle.main.object(forInfoDictionaryKey: "FritzKeychainService") as? String ?? "dev.fritz.provider-credentials", modelCatalog: modelCatalog)
    }
}
