import Fritz
import Foundation

struct ProjectThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New Thread"
    var createdAt = Date()
    var titleIsAutomatic = true
}

struct FritzProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var directory: String?
    var threads: [ProjectThread] = []
}

struct WorkspaceDocument: Codable, Equatable {
    var projects: [FritzProject] = []
    var selectedThreadID: UUID?

    func validate() throws {
        let projectIDs = projects.map(\.id)
        let threadIDs = projects.flatMap(\.threads).map(\.id)
        guard Set(projectIDs).count == projectIDs.count,
              Set(threadIDs).count == threadIDs.count,
              selectedThreadID == nil || threadIDs.contains(selectedThreadID!) else {
            throw AgentFailure(message: "The saved workspace is invalid or uses an unsupported version.")
        }
    }
}
