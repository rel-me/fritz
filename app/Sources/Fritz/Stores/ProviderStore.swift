import Fritz
import FritzUI

typealias ProviderStore = ModelsStore

extension ModelsStore {
    convenience init(agent: AgentClient, database: AppDatabase) {
        self.init(agent: agent, preferences: database)
    }
}
