import AppKit
import SwiftUI

struct ConfigurationDownloadLocation: View {
    let directory: URL?
    let choose: (URL) -> Void
    @State private var panel: NSOpenPanel?

    var body: some View {
        HStack(spacing: 8) {
            Text("Download to")
            Spacer(minLength: 8)
            Text(directory?.path ?? "Choose a folder")
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(directory?.path ?? "Choose a folder")
                .accessibilityLabel("Download location")
                .accessibilityValue(directory?.path ?? "Choose a folder")
            Button("Choose…", action: chooseFolder)
                .fixedSize()
                .accessibilityLabel("Choose download folder")
        }
        .onDisappear { panel?.cancel(nil); panel = nil }
    }

    private func chooseFolder() {
        guard panel == nil else { return }
        let picker = NSOpenPanel()
        picker.preventsApplicationTerminationWhenModal = false
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        picker.canCreateDirectories = true
        picker.directoryURL = directory
        picker.prompt = "Choose"
        panel = picker
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = picker.url { choose(url) }
            panel = nil
        }
        if let window = NSApp.keyWindow {
            picker.beginSheetModal(for: window, completionHandler: completion)
        } else {
            picker.begin(completionHandler: completion)
        }
    }
}
