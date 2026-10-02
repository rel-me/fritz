import AppKit
import NativeMarkupUI
import SwiftUI

struct WorkspaceRightPanel: View {
    let store: MarkupPanelStore
    let close: () -> Void
    @State private var windowAnchor = MarkupPanelWindowAnchor()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Markup").font(.headline)
                Spacer()
                Button("Close Right Panel", systemImage: "xmark", action: close)
                    .modifier(FritzPanelIconControl())
            }
            .padding(8)

            HStack {
                Text(store.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(store.loader.fileURL?.path ?? "Sample")
                Spacer()
                if store.loader.fileURL != nil || store.diagnostic != nil {
                    Text(store.status).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Button("Open Markup…") { store.chooseFile(in: windowAnchor.window) }
                .buttonStyle(FritzButtonStyle(.content))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            Divider()

            ScrollView {
                MarkupView(session: store.session)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }

            if let diagnostic = store.diagnostic {
                Divider()
                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FritzWindowStyle.contentBackground)
        .background { MarkupPanelWindowReader(anchor: windowAnchor) }
        .onAppear(perform: store.synchronizeSource)
        .onChange(of: store.loader.source) { _, _ in store.synchronizeSource() }
    }
}

/// The picker belongs to this panel's window even when the app is inactive.
@MainActor private final class MarkupPanelWindowAnchor {
    weak var window: NSWindow?
}

private struct MarkupPanelWindowReader: NSViewRepresentable {
    let anchor: MarkupPanelWindowAnchor

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.anchor = anchor
        return view
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.anchor = anchor
        nsView.captureWindow()
    }

    final class WindowView: NSView {
        var anchor: MarkupPanelWindowAnchor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            captureWindow()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func captureWindow() {
            anchor?.window = window
        }
    }
}
