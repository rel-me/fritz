import AppKit

@MainActor
enum ChatResponseClipboard {
    @discardableResult
    static func copy(
        _ response: String,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(response, forType: .string)
    }
}
