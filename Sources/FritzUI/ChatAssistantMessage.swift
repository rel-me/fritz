import Fritz
import SwiftUI

public struct ChatAssistantMessage<Content: View>: View {
    private let copy: () -> Bool
    private let usage: ChatResponseUsageSummary?
    private let content: () -> Content

    public init(copy: @escaping () -> Bool, usage: ChatResponseUsageSummary? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.copy = copy
        self.usage = usage
        self.content = content
    }

    @State private var isCopied = false
    @State private var resetCopiedTask: Task<Void, Never>?

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Button(
                    isCopied ? "Copied" : "Copy response",
                    systemImage: isCopied ? "checkmark" : "doc.on.doc",
                    action: copyResponse
                )
                .modifier(FritzPanelIconControl(isEmphasized: isCopied))
                .help(isCopied ? "Copied" : "Copy response")
                .accessibilityInputLabels(["Copy response"])
                if let usage { ChatResponseUsageButton(summary: usage) }
            }
        }
        .onDisappear(perform: cancelResetCopiedTask)
    }

    private func copyResponse() {
        guard copy() else { return }
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
