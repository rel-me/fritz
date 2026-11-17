import Fritz
import Foundation

struct ProjectThread: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New Chat"
    var createdAt = Date()
    var titleIsAutomatic = true
    var isArchived = false

    enum CodingKeys: String, CodingKey { case id, title, createdAt, titleIsAutomatic, isArchived }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        titleIsAutomatic = try values.decode(Bool.self, forKey: .titleIsAutomatic)
        isArchived = try values.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
    }
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
