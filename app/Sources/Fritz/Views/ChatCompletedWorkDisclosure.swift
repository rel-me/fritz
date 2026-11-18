import FritzUI
import SwiftUI

struct ChatCompletedWorkDisclosure: View {
    let message: ChatMessage
    let repository: ProjectRepository

    var body: some View {
        FritzUI.ChatCompletedWorkDisclosure(summary: message.workSummary, hasActivities: message.toolCount > 0) {
            StoredChatActivities(id: message.id, repository: repository)
        }
    }
}

private struct StoredChatActivities: View {
    let id: UUID
    let repository: ProjectRepository
    @State private var activities: [ChatToolActivity]?
    @State private var error: String?

    var body: some View {
        Group {
            if let activities {
                ChatActivityRow(activities: activities, maximumActivityCount: nil, showsHeading: false,
                                isActive: false, entryID: id, repository: repository)
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
        }
        .task {
            do { activities = try await repository.tools(id) }
            catch { self.error = error.localizedDescription }
        }
    }
}
