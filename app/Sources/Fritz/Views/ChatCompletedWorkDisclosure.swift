import SwiftUI

struct ChatCompletedWorkDisclosure: View {
    let message: ChatMessage

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if (message.tools ?? []).isEmpty {
                Text(message.workSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Text(message.workSummary)

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
                ChatActivityRow(
                    activities: message.tools ?? [],
                    maximumActivityCount: nil,
                    showsHeading: false,
                    isActive: false
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleExpanded() {
        isExpanded.toggle()
    }
}
