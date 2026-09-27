import SwiftUI

public struct ChatCompletedWorkDisclosure<Activities: View>: View {
    private let summary: String
    private let hasActivities: Bool
    private let activities: () -> Activities

    public init(summary: String, hasActivities: Bool, @ViewBuilder activities: @escaping () -> Activities) {
        self.summary = summary
        self.hasActivities = hasActivities
        self.activities = activities
    }

    @State private var isExpanded = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !hasActivities {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Text(summary)

                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .accessibilityHidden(true)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(FritzButtonStyle(.inline))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .help(isExpanded ? "Hide work" : "Show work")
            }

            Divider()

            if isExpanded {
                activities()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}
