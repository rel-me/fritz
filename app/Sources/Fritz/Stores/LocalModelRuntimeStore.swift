import Fritz
import FritzUI

typealias LocalModelRuntimeStore = ModelsLocalRuntime

extension ModelsLocalRuntime {
    convenience init(agent: AgentClient, database: AppDatabase) {
        self.init(agent: agent, preferences: database)
    }
}
