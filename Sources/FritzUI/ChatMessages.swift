import SwiftUI

public struct ChatUserMessage: View {
    let content: String

    public init(content: String) { self.content = content }

    public var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 52)

            Text(content)
                .font(.body)
                .chatTextSelection()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Color.primary.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .frame(maxWidth: 620, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

public struct ChatErrorMessage: View {
    let content: String

    public init(content: String) { self.content = content }

    public var body: some View {
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
                    .chatTextSelection()
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

public struct ChatStatusMessage: View {
    let content: String

    public init(content: String) { self.content = content }

    public var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.72))
                .frame(height: 1)

            Text(content)
                .fixedSize()

            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.72))
                .frame(height: 1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }
}


// Shader copies must remain SwiftUI-drawn; selection is owned by the original row.
private struct ChatVisualEffectCopyKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var chatIsVisualEffectCopy: Bool {
        get { self[ChatVisualEffectCopyKey.self] }
        set { self[ChatVisualEffectCopyKey.self] = newValue }
    }
}

private struct ChatTextSelection: ViewModifier {
    @Environment(\.chatIsVisualEffectCopy) private var isVisualEffectCopy

    @ViewBuilder func body(content: Content) -> some View {
        if isVisualEffectCopy {
            content.textSelection(.disabled)
        } else {
            content.textSelection(.enabled)
        }
    }
}

public extension View {
    func chatTextSelection() -> some View {
        modifier(ChatTextSelection())
    }
}
