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

private struct ChatUserMessage: View {
    let content: String

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 52)

            Text(content)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    ChatVisualStyle.subtleFill,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .frame(maxWidth: 620, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ChatErrorMessage: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Something went wrong")
                    .font(.callout.weight(.semibold))

                Text(content)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)
        }
        .padding(12)
        .background(Color.red.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.red.opacity(0.16))
        }
    }
}

struct ChatStatusMessage: View {
    let content: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(ChatVisualStyle.hairline)
                .frame(height: 1)

            Text(content)
                .fixedSize()

            Rectangle()
                .fill(ChatVisualStyle.hairline)
                .frame(height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
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
            if showsHeading {
                HStack(spacing: 8) {
                    Text(visibleActivities.isEmpty ? "Thinking" : "Working")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .frame(width: 64)
                        .accessibilityLabel(
                            visibleActivities.isEmpty ? "Agent thinking" : "Agent working"
                        )
                }
            }

            if let activity, showsHeading, !activities.contains(where: { $0.summary == activity }) {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if !visibleActivities.isEmpty {
                if showsHeading {
                    Divider()
                }

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(visibleActivities) { activity in
                        ChatActivityItem(activity: activity, isActive: isActive)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleActivities: [ChatToolActivity] {
        guard let maximumActivityCount else { return activities }
        return Array(activities.suffix(maximumActivityCount))
    }
}

private struct ChatActivityItem: View {
    let activity: ChatToolActivity
    let isActive: Bool
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(alignment: .top, spacing: 7) {
                ChatActivityStatusMark(status: activity.status(isActive: isActive))

                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.name.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.callout)
                        .foregroundStyle(activity.success == false ? .secondary : .primary)

                    Text(activity.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(FritzButtonStyle(.inline))
        .accessibilityElement(children: .combine)
        .help("Show tool arguments and result")
        .popover(isPresented: $showsDetails) {
            ChatToolDetails(activity: activity, isActive: isActive)
        }
    }
}

private struct ChatActivityStatusMark: View {
    let status: ChatActivityStatus

    @ViewBuilder
    var body: some View {
        switch status {
        case .running:
            Image(systemName: "circle.fill")
                .font(.caption2)
                .foregroundStyle(.primary)
                .accessibilityLabel("In progress")
        case .completed:
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Completed")
        case .interrupted:
            Image(systemName: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Interrupted")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Failed")
        }
    }
}
