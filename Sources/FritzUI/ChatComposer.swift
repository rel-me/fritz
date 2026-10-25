import SwiftUI
import Fritz

public struct ChatComposer<Models: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var draft: String
    let placeholder: String
    let canSend: Bool
    let isResponding: Bool
    let isFocused: FocusState<Bool>.Binding
    private let models: () -> Models
    private let background: Color
    private let cornerRadius: CGFloat
    let send: () -> Void
    let stop: () -> Void
    private var mentionDraft: Binding<ChatMentionDraft>?
    private var mentionRegistry: ChatMentionRegistry?
    @State private var mentionSelection = NSRange(location: 0, length: 0)
    @State private var selectedMentionID: ChatMentionItem.ID?
    @State private var dismissedQuery: NSRange?

    public init(draft: Binding<String>, placeholder: String, canSend: Bool,
                isResponding: Bool, isFocused: FocusState<Bool>.Binding,
                background: Color = Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(srgbRed: 69.0 / 255.0, green: 69.0 / 255.0,
                                  blue: 69.0 / 255.0, alpha: 1)
                        : .textBackgroundColor
                }), cornerRadius: CGFloat = 12,
                send: @escaping () -> Void, stop: @escaping () -> Void,
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
        self.models = models
    }

    /// The host receives stable references in `mentions` and owns their persistence and resolution.
    public init(mentions: Binding<ChatMentionDraft>, registry: ChatMentionRegistry,
                placeholder: String, canSend: Bool, isResponding: Bool,
                isFocused: FocusState<Bool>.Binding,
                background: Color? = nil, cornerRadius: CGFloat = 12,
                send: @escaping () -> Void, stop: @escaping () -> Void,
                @ViewBuilder models: @escaping () -> Models) {
        self.init(draft: Binding(
            get: { mentions.wrappedValue.text },
            set: { mentions.wrappedValue.updateText($0) }
        ), placeholder: placeholder, canSend: canSend, isResponding: isResponding,
                  isFocused: isFocused,
                  background: background ?? Color(nsColor: NSColor(name: nil) { appearance in
                      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                          ? NSColor(srgbRed: 69.0 / 255.0, green: 69.0 / 255.0,
                                    blue: 69.0 / 255.0, alpha: 1)
                          : .textBackgroundColor
                  }), cornerRadius: cornerRadius, send: send, stop: stop, models: models)
        self.mentionDraft = mentions
        self.mentionRegistry = registry
    }

    public var body: some View {
        VStack(spacing: 0) {
            if activeMentionQuery != nil {
                mentionPicker
            }
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
                if !key.modifiers.contains(.shift), chooseCurrentMention() { return .handled }
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
            .onKeyPress(.upArrow) { moveMentionSelection(-1) }
            .onKeyPress(.downArrow) { moveMentionSelection(1) }
            .onKeyPress(.tab) { chooseCurrentMention() ? .handled : .ignored }
            .onKeyPress(.escape) {
                guard let query = activeMentionQuery else { return .ignored }
                dismissedQuery = query.range
                return .handled
            }
            .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { note in
                guard mentionDraft != nil, isFocused.wrappedValue,
                      let editor = note.object as? NSTextView,
                      editor === NSApp.keyWindow?.firstResponder,
                      editor.string == draft else { return }
                mentionSelection = editor.selectedRange()
            }
            .onChange(of: draft) {
                dismissedQuery = nil
                selectedMentionID = nil
                if isFocused.wrappedValue,
                   let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
                   editor.string == draft {
                    mentionSelection = editor.selectedRange()
                }
            }
            .frame(minHeight: 44, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
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

    private var activeMentionQuery: (range: NSRange, text: String)? {
        guard isFocused.wrappedValue, !isResponding,
              let query = mentionDraft?.wrappedValue.query(at: mentionSelection),
              query.range != dismissedQuery else { return nil }
        return query
    }

    private var mentionMatches: [ChatMentionItem] {
        guard let query = activeMentionQuery else { return [] }
        return mentionRegistry?.search(query.text) ?? []
    }

    private var currentMention: ChatMentionItem? {
        mentionMatches.first { $0.id == selectedMentionID } ?? mentionMatches.first
    }

    private var mentionPicker: some View {
        let items = mentionMatches
        let activeID = items.first { $0.id == selectedMentionID }?.id ?? items.first?.id
        return VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("No references found")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(items) { item in
                                Button { chooseMention(item) } label: {
                                    HStack {
                                        Image(systemName: item.kind == .plugin ? "puzzlepiece.extension" :
                                                item.kind == .artifact ? "doc" : "at")
                                        VStack(alignment: .leading) {
                                            Text(item.name)
                                            if !item.detail.isEmpty {
                                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(item.id.source).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(8)
                                    .contentShape(Rectangle())
                                    .background(activeID == item.id ? Color.accentColor.opacity(0.15) : .clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(item.name), \(item.kind.rawValue), \(item.id.source), \(item.detail)")
                                .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(height: min(CGFloat(items.count) * 58 + 12, 220))
                    .onChange(of: selectedMentionID) {
                        if let selectedMentionID { proxy.scrollTo(selectedMentionID) }
                    }
                }
            }
            Divider()
        }
        .accessibilityLabel("References")
    }

    private func moveMentionSelection(_ delta: Int) -> KeyPress.Result {
        let items = mentionMatches
        guard !items.isEmpty else { return .ignored }
        let index = items.firstIndex { $0.id == currentMention?.id } ?? 0
        selectedMentionID = items[(index + delta + items.count) % items.count].id
        return .handled
    }

    private func chooseCurrentMention() -> Bool {
        guard let item = currentMention else { return false }
        chooseMention(item)
        return true
    }

    private func chooseMention(_ item: ChatMentionItem) {
        guard let mentionDraft, let query = activeMentionQuery else { return }
        // Use the native edit operation so undo, selection and IME ownership remain native.
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
              editor.string == draft else { return }
        var value = mentionDraft.wrappedValue
        editor.insertText("@" + item.name + " ", replacementRange: query.range)
        _ = value.insert(item, replacing: query.range)
        mentionDraft.wrappedValue = value
        mentionSelection = editor.selectedRange()
        selectedMentionID = nil
    }

    private func performPrimaryAction() {
        if isResponding {
            stop()
        } else {
            submitMessage()
        }
    }

    private func submitMessage() {
        if chooseCurrentMention() { return }
        guard canSend, !isResponding else { return }
        send()
    }

    private func focusMessageField() {
        isFocused.wrappedValue = true
    }
}
