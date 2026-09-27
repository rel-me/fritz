import FritzUI
import SwiftUI

struct ChatCompletedWorkDisclosure: View {
    let message: ChatMessage

    var body: some View {
        FritzUI.ChatCompletedWorkDisclosure(summary: message.workSummary, hasActivities: !(message.tools ?? []).isEmpty) {
            ChatActivityRow(
                activities: message.tools ?? [],
                maximumActivityCount: nil,
                showsHeading: false,
                isActive: false
            )
        }
    }
}
