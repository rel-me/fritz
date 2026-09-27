import SwiftUI

public struct ChatComposer<Options: View, Models: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var draft: String
    let placeholder: String
    let canSend: Bool
    let isResponding: Bool
    let isFocused: FocusState<Bool>.Binding
    private let options: () -> Options
    private let models: () -> Models
    private let background: Color
    private let cornerRadius: CGFloat
    let send: () -> Void
    let stop: () -> Void

    public init(draft: Binding<String>, placeholder: String, canSend: Bool,
                isResponding: Bool, isFocused: FocusState<Bool>.Binding,
                background: Color = Color(nsColor: .textBackgroundColor), cornerRadius: CGFloat = 12,
                send: @escaping () -> Void, stop: @escaping () -> Void,
                @ViewBuilder options: @escaping () -> Options,
                @ViewBuilder models: @escaping () -> Models) {
        self._draft = draft
        self.placeholder = placeholder
        self.canSend = canSend
        self.isResponding = isResponding
        self.isFocused = isFocused
        self.background = background
        self.cornerRadius = cornerRadius
        self.send = send
        self.stop = stop
        self.options = options
        self.models = models
    }

    public var body: some View {
        VStack(spacing: 0) {
            TextField(
                placeholder,
                text: $draft,
                prompt: Text(placeholder)
                    .foregroundStyle(Color.secondary),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.body)
            .accessibilityLabel("Message")
            .lineLimit(1...20)
            .fixedSize(horizontal: false, vertical: true)
            .focused(isFocused)
            .onSubmit(submitMessage)
            .onKeyPress(.return, phases: .down) { key in
                if key.modifiers.contains(.shift) {
                    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                        return .ignored
                    }
                    editor.insertText("\n", replacementRange: editor.selectedRange())
                    return .handled
                }
                submitMessage()
                return .handled
            }
            .frame(minHeight: 44, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                Menu("Chat Options", systemImage: "ellipsis.circle") {
                    options()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .modifier(FritzPanelIconControl())
                .accessibilityIdentifier("chat-options")
                .help("Chat Options")

                Spacer(minLength: 6)

                models()

                Button(action: performPrimaryAction) {
                    Image(systemName: isResponding ? "stop.fill" : "arrow.up")
                        .font(isResponding ? .callout.weight(.bold) : .system(size: 15, weight: .regular))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(FritzButtonStyle(.floatingPrimary, size: .regular, shape: .circle))
                .accessibilityLabel(isResponding ? "Stop" : "Send")
                .disabled(!isResponding && !canSend)
                .keyboardShortcut(isResponding ? .cancelAction : .defaultAction)
                .help(isResponding ? "Stop Agent" : "Send Message")
            }
            .modifier(FritzGlassControlGroup())
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .padding(.bottom, 9)
        }
        .background {
            Button(action: focusMessageField) {
                RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                )
                .fill(background)
            }
            .buttonStyle(FritzButtonStyle(.inline))
            .accessibilityHidden(true)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.12 : 0.04),
            radius: 6,
            y: 2
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func performPrimaryAction() {
        if isResponding {
            stop()
        } else {
            submitMessage()
        }
    }

    private func submitMessage() {
        guard canSend, !isResponding else { return }
        send()
    }

    private func focusMessageField() {
        isFocused.wrappedValue = true
    }
}

