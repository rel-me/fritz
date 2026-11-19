import FritzUI
import SwiftUI

// Adapted from REL's native message and activity views.
struct ChatMessageRow: View {
    let message: ChatMessage
    let isActive: Bool
    let activity: String?
    let activeTools: [ChatToolActivity]
    let repository: ProjectRepository
    let openBody: () -> Void

    var body: some View {
        let showsStopOnly = !isActive && message.wasStoppedByUser
        VStack(alignment: .leading, spacing: ChatVisualStyle.transcriptSpacing) {
            if message.role == "user" {
                ChatUserMessage(content: message.content)
            } else if showsStopOnly {
                Text(message.workSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                if isActive {
                    ChatActivityRow(activities: activeTools, activity: activity, entryID: message.id, repository: repository)
                } else if message.elapsedTime != nil || message.toolCount > 0 {
                    ChatCompletedWorkDisclosure(message: message, repository: repository)
                }
                if !message.content.isEmpty {
                    ChatAssistantMessage(content: message.content)
                }
                if !message.isComplete && !isActive {
                    ChatStatusMessage(content: "Response interrupted")
                }
                if !isActive, let summary = message.usageSummary {
                    FritzUI.ChatResponseUsageFooter(summary: summary)
                }
            }
            if message.hasMoreBody && !showsStopOnly {
                Button("Read Full Message", action: openBody)
                    .buttonStyle(.link)
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
    let entryID: UUID
    let repository: ProjectRepository

    init(
        activities: [ChatToolActivity],
        maximumActivityCount: Int? = 6,
        showsHeading: Bool = true,
        isActive: Bool = true,
        activity: String? = nil,
        entryID: UUID,
        repository: ProjectRepository
    ) {
        self.activities = activities
        self.maximumActivityCount = maximumActivityCount
        self.showsHeading = showsHeading
        self.isActive = isActive
        self.activity = activity
        self.entryID = entryID
        self.repository = repository
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
                    ChatStoredToolDetails(activity: tool, isActive: isActive, entryID: entryID, repository: repository)
                }
            }

        }
    }
}

struct ChatStoredBody: View {
    let entry: ChatMessage
    let repository: ProjectRepository
    @Environment(\.dismiss) private var dismiss
    @State private var chunks: [String] = []
    @State private var cursor: Int64 = 0
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        FritzDialog {
            Group {
                if let error { Text(error).foregroundStyle(.red) }
                else if isLoading { ProgressView() }
                else {
                    ScrollView {
                        Text(chunks.joined()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 24)
        } actions: {
            if cursor > 0 { Button("Previous") { Task { await load(max(0, cursor - 4)) } }.disabled(isLoading) }
            if hasMore { Button("Next") { Task { await load(cursor + 4) } }.disabled(isLoading) }
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 12)
        .frame(width: 640, height: 440)
        .task { await load(0) }
    }

    private func load(_ offset: Int64) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.body(entry.id, from: offset)
            chunks = Array(page.prefix(4))
            hasMore = page.count > 4
            cursor = offset
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct ChatStoredToolDetails: View {
    let activity: ChatToolActivity
    let isActive: Bool
    let entryID: UUID
    let repository: ProjectRepository
    @State private var loaded: ChatToolActivity?
    @State private var error: String?

    var body: some View {
        Group {
            if let loaded { ChatToolDetails(activity: loaded, isActive: isActive) }
            else if let error { Text(error).padding() }
            else { ProgressView().padding() }
        }
        .task(id: activity.success) {
            do {
                loaded = try await repository.tool(entryID, callID: activity.id)
                if loaded == nil { error = "This tool record is unavailable." }
            } catch { self.error = error.localizedDescription }
        }
    }
}
