import SwiftUI

public enum ChatActivityStatus: String, Sendable {
    case running, completed, interrupted, failed
}

public struct ChatActivity: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String?
    public let status: ChatActivityStatus
    public let hasDetails: Bool

    public init(id: String, title: String, detail: String? = nil,
                status: ChatActivityStatus, hasDetails: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.hasDetails = hasDetails
    }
}

public struct ChatActivityRow<Details: View>: View {
    let activities: [ChatActivity]
    let details: (ChatActivity) -> Details
    let maximumActivityCount: Int?
    let showsHeading: Bool
    let headingDetail: String?

    public init(
        activities: [ChatActivity],
        maximumActivityCount: Int? = 6,
        showsHeading: Bool = true,
        headingDetail: String? = nil,
        @ViewBuilder details: @escaping (ChatActivity) -> Details
    ) {
        self.activities = activities
        self.details = details
        self.maximumActivityCount = maximumActivityCount
        self.headingDetail = headingDetail
        self.showsHeading = showsHeading
    }

    public var body: some View {
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

            if showsHeading, let headingDetail {
                Text(headingDetail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }

            if !visibleActivities.isEmpty {
                if showsHeading {
                    Divider()
                }

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(visibleActivities) { activity in
                        ChatActivityItem(activity: activity) { details(activity) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var visibleActivities: [ChatActivity] {
        guard let maximumActivityCount else { return activities }
        return Array(activities.suffix(maximumActivityCount))
    }
}

private struct ChatActivityItem<Details: View>: View {
    let activity: ChatActivity
    @ViewBuilder let details: () -> Details
    @State private var showsDetails = false

    var body: some View {
        if activity.hasDetails {
            Button { showsDetails = true } label: { label }
                .buttonStyle(FritzButtonStyle(.inline))
                .help("Show tool arguments and result")
                .popover(isPresented: $showsDetails) {
                    details()
                }
        } else {
            label
                .textSelection(.enabled)
        }
    }

    private var label: some View {
        HStack(alignment: .top, spacing: 7) {
            ChatActivityStatusMark(status: activity.status)

            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title)
                    .font(.callout)
                    .foregroundStyle(activity.status == .failed ? .secondary : .primary)

                if let detail = activity.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
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

