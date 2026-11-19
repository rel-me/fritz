import Fritz
import SwiftUI

public struct ChatResponseUsageFooter: View {
    private let summary: ChatResponseUsageSummary

    public init(summary: ChatResponseUsageSummary) { self.summary = summary }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            labels
            VStack(alignment: .leading, spacing: 4) {
                Text(tokens)
                Text(cached)
                Text(summary.costLabel)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .chatTextSelection()
        .help("\(summary.modelName). Cached input is included in total tokens. \(summary.costSource == "rel.me" ? "Prices from REL’s model catalog. " : "")Provider billing is authoritative.")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-response-usage-footer")
    }

    private var tokens: String {
        summary.usage.reportedModelCalls == 0 && summary.usage.knownTokens == 0 ? "Tokens unavailable" : "\(summary.usage.knownTokens.formatted()) tokens\(summary.usage.unreportedModelCalls > 0 ? " (partial)" : "")"
    }
    private var cached: String {
        summary.usage.reportedModelCalls == 0 ? "Cached tokens unavailable" : "\(summary.usage.cachedInputTokens.formatted()) cached"
    }
    private var labels: some View {
        HStack(spacing: 8) {
            Text(tokens)
            Text("·")
            Text(cached)
            Text("·")
            Text(summary.costLabel)
        }
    }
}

/// Shows response usage alongside the message's other actions.
public struct ChatResponseUsageButton: View {
    private let summary: ChatResponseUsageSummary
    @State private var isPresented = false
    @State private var isPinned = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @FocusState private var isPopoverFocused: Bool

    public init(summary: ChatResponseUsageSummary) { self.summary = summary }

    public var body: some View {
        Button("Response usage", systemImage: "info.circle") {
            isPinned.toggle()
            isPresented = isPinned
        }
        .modifier(FritzPanelIconControl(isEmphasized: isPresented))
        .onHover { hovering in
            isHoveringButton = hovering
            if hovering { isPresented = true }
        }
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary.modelName).font(.headline)
                ChatResponseUsageFooter(summary: summary)
            }
            .padding(12)
            .frame(idealWidth: 260)
            .onHover { isHoveringPopover = $0 }
            .focusable(isPinned)
            .focusEffectDisabled()
            .focused($isPopoverFocused)
            .onExitCommand { isPresented = false }
            .task(id: isPinned) {
                guard isPinned else { return }
                await Task.yield()
                if !Task.isCancelled { isPopoverFocused = true }
            }
        }
        .onChange(of: isPresented) { _, presented in
            if !presented {
                isPinned = false
                isHoveringPopover = false
            }
        }
        .task(id: shouldDismissPreview) {
            guard shouldDismissPreview else { return }
            // Give the pointer time to cross from the button to the popover.
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, shouldDismissPreview else { return }
            isPresented = false
        }
    }

    private var shouldDismissPreview: Bool {
        isPresented && !isPinned && !isHoveringButton && !isHoveringPopover
    }
}
