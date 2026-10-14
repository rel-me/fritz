import FritzUI
import SwiftUI
import Textual

struct ChatAssistantMessage: View {
    let content: String
    @Environment(\.chatIsVisualEffectCopy) private var isVisualEffectCopy

    var body: some View {
        FritzUI.ChatAssistantMessage(copy: { ChatResponseClipboard.copy(content) }) {
            if isVisualEffectCopy {
                markdown.textual.textSelection(.disabled)
            } else {
                markdown.textual.textSelection(.enabled)
            }
        }
    }

    private var markdown: some View {
        StructuredText(markdown: content)
            .textual.structuredTextStyle(.gitHub)
    }
}
