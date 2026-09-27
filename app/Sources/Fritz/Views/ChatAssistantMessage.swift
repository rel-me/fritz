import FritzUI
import SwiftUI
import Textual

struct ChatAssistantMessage: View {
    let content: String

    var body: some View {
        FritzUI.ChatAssistantMessage(copy: { ChatResponseClipboard.copy(content) }) {
            StructuredText(markdown: content)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
        }
    }
}
