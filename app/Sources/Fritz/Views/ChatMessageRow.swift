import FritzUI
import SwiftUI

// Adapted from REL's native message and activity views.
struct ChatMessageRow: View {
    let message: ChatMessage
    let isActive: Bool
    let activity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
            if message.role == "user" {
                ChatUserMessage(content: message.content)
            } else {
                if isActive {
                    ChatActivityRow(activities: message.tools ?? [], activity: activity)
                } else if message.elapsedTime != nil || !(message.tools ?? []).isEmpty {
                    ChatCompletedWorkDisclosure(message: message)
                }
                if !message.content.isEmpty {
                    ChatAssistantMessage(content: message.content)
                }
                if !message.isComplete && !isActive {
                    ChatStatusMessage(content: "Response interrupted")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatActivityRow: View {
    let activities: [ChatToolActivity]
    let maximumActivityCount: Int?
    let showsHeading: Bool
    let isActive: Bool
    let activity: String?

    init(
        activities: [ChatToolActivity],
        maximumActivityCount: Int? = 6,
        showsHeading: Bool = true,
        isActive: Bool = true,
        activity: String? = nil
    ) {
        self.activities = activities
        self.maximumActivityCount = maximumActivityCount
        self.showsHeading = showsHeading
        self.isActive = isActive
        self.activity = activity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FritzUI.ChatActivityRow(
                activities: activities.map {
                    FritzUI.ChatActivity(id: $0.id,
                        title: $0.name.replacingOccurrences(of: "_", with: " ").capitalized,
                        detail: $0.summary,
                        status: $0.status(isActive: isActive).presentation,
                        hasDetails: true)
                }, maximumActivityCount: maximumActivityCount, showsHeading: showsHeading,
                headingDetail: activity.flatMap { detail in
                    activities.contains(where: { $0.summary == detail }) ? nil : detail
                }
            ) { item in
                if let tool = activities.first(where: { $0.id == item.id }) {
                    ChatToolDetails(activity: tool, isActive: isActive)
                }
            }

        }
    }
}
