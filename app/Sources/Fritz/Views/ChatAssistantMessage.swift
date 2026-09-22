import SwiftUI
import Textual

struct ChatAssistantMessage: View {
    let content: String

    @State private var isCopied = false
    @State private var resetCopiedTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StructuredText(markdown: content)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(
                isCopied ? "Copied" : "Copy response",
                systemImage: isCopied ? "checkmark" : "doc.on.doc",
                action: copyResponse
            )
            .modifier(FritzPanelIconControl(isEmphasized: isCopied))
            .help(isCopied ? "Copied" : "Copy response")
            .accessibilityInputLabels(["Copy response"])
        }
        .onDisappear(perform: cancelResetCopiedTask)
    }

    private func copyResponse() {
        guard ChatResponseClipboard.copy(content) else { return }
        resetCopiedTask?.cancel()
        isCopied = true
        resetCopiedTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            isCopied = false
            resetCopiedTask = nil
        }
    }

    private func cancelResetCopiedTask() {
        resetCopiedTask?.cancel()
        resetCopiedTask = nil
    }
}
