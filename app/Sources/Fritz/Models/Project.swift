import Foundation

struct ProjectThread: Identifiable, Equatable, Sendable {
    let id: UUID
    let projectID: UUID
    let position: Int64
    let title: String
    let isArchived: Bool
}

struct ArchivedChat: Identifiable, Sendable {
    let id: UUID
    let title: String
    let projectName: String
    let updatedAt: Int64
    let position: Int64
}

struct FritzProject: Identifiable, Equatable, Sendable {
    let id: UUID
    let position: Int64
    let name: String
    let directory: String?
}

struct ProjectSelection: Sendable {
    let project: FritzProject
    let thread: ProjectThread
}

struct SidebarPage<Row: Sendable>: Sendable {
    var rows: [Row] = []
    var hasMore = false
}
