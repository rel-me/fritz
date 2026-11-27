import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// AppKit owns the compact folder icon, hierarchy menu and standard Choose panel.
struct ModelStoragePathControl: NSViewRepresentable {
    let directory: URL?
    let choose: ((URL) -> Void)?
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .popUp
        control.isEditable = choose != nil
        control.placeholderString = "Choose a folder…"
        control.delegate = context.coordinator
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(choose == nil ? "Stored model folder" : "Model storage folder")
        return control
    }
    static func dismantleNSView(_ control: NSPathControl, coordinator: Coordinator) {
        coordinator.panel?.cancel(nil)
    }
    func updateNSView(_ control: NSPathControl, context: Context) {
        context.coordinator.parent = self
        control.isEnabled = context.environment.isEnabled
        control.isEditable = choose != nil
        control.url = directory
        control.toolTip = directory?.path
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSPathControl, context: Context) -> CGSize? {
        guard choose == nil else { return nil }
        let size = control.intrinsicContentSize
        // The native pop-up's intrinsic width leaves extra space before its chevrons.
        let width = size.width - 22
        return CGSize(width: min(proposal.width ?? width, width), height: proposal.height ?? size.height)
    }
    @MainActor final class Coordinator: NSObject, NSPathControlDelegate {
        weak var panel: NSOpenPanel?
        var parent: ModelStoragePathControl
        init(_ parent: ModelStoragePathControl) { self.parent = parent }
        @objc func changed(_ control: NSPathControl) {
            let selected = control.url
            control.url = parent.directory // A selection is a proposal until the storage operation commits.
            if let selected, selected != parent.directory { parent.choose?(selected) }
        }
        @objc func reveal(_ sender: NSMenuItem) {
            if let directory = parent.directory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
        }
        func pathControl(_ pathControl: NSPathControl, willPopUp menu: NSMenu) {
            guard parent.directory != nil else { return }
            menu.addItem(.separator())
            let item = NSMenuItem(title: "Show in Finder", action: #selector(reveal(_:)), keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        func pathControl(_ pathControl: NSPathControl, willDisplay openPanel: NSOpenPanel) {
            panel = openPanel
            openPanel.canChooseFiles = false; openPanel.canChooseDirectories = true
            openPanel.allowsMultipleSelection = false; openPanel.canCreateDirectories = true
            openPanel.allowedContentTypes = [.folder]
            openPanel.preventsApplicationTerminationWhenModal = false
            openPanel.prompt = "Choose"
        }
    }
}

public struct ModelStorageLocation: View {
    @Bindable private var storage: ModelStorage
    @State private var destination: URL?
    @State private var previous = ""
    @State private var confirmsMove = false
    @State private var showsProgress = false
    @State private var task: Task<Void, Never>?
    public init(storage: ModelStorage) { self.storage = storage }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Model storage") {
                ModelStoragePathControl(directory: storage.info.map { URL(fileURLWithPath: $0.directory) }, choose: propose)
                    .frame(minWidth: 140, idealWidth: 220, maxWidth: 300, minHeight: 24)
                    .disabled(storage.isBusy || storage.info == nil)
            }
            if let error = storage.error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                if storage.info == nil { Button("Retry") { task = Task { await storage.refresh() } } }
            }
            if let warning = storage.info?.warning { Text(warning).foregroundStyle(.secondary).font(.callout).textSelection(.enabled) }
        }
        .task { await storage.refresh() }
        .onDisappear { task?.cancel() }
        .onChange(of: storage.isBusy) { _, busy in
            if !busy && storage.error == nil && storage.info?.warning == nil {
                task = Task { await storage.refresh() }
            }
        }
        .confirmationDialog("Move existing models?", isPresented: $confirmsMove, titleVisibility: .visible) {
            Button("Move Models") { showsProgress = true }
            Button("Keep Existing") { apply(move: false) }
            Button("Cancel", role: .cancel) { destination = nil }
        } message: {
            if let info = storage.info, let destination {
                Text("\(info.modelCount) downloaded \(info.modelCount == 1 ? "model" : "models") (\(ByteCountFormatter.string(fromByteCount: Int64(clamping: info.bytes), countStyle: .file))) \(info.modelCount == 1 ? "is" : "are") in the previous folder. New downloads will use “\(destination.lastPathComponent)”.")
            }
        }
        .sheet(isPresented: $showsProgress) {
            ModelStorageMoveSheet(storage: storage, cancel: { showsProgress = false })
                .task {
                    if let destination { await storage.change(to: destination, previous: previous, moveModels: true) }
                    showsProgress = false
                }
        }
    }
    private func propose(_ url: URL) {
        task?.cancel()
        task = Task {
            await storage.refresh()
            guard !Task.isCancelled, let info = storage.info, storage.error == nil else { return }
            guard url.standardizedFileURL.path != URL(fileURLWithPath: info.directory).standardizedFileURL.path else { return }
            destination = url; previous = info.directory
            if info.modelCount > 0 { confirmsMove = true } else { apply(move: false) }
        }
    }
    private func apply(move: Bool) {
        guard let destination else { return }
        task = Task { await storage.change(to: destination, previous: previous, moveModels: move) }
    }
}

struct ModelStorageMoveSheet: View {
    let storage: ModelStorage
    let cancel: () -> Void

    var body: some View {
        FritzDialog("Moving Models") {
            Form {
                Section {
                    ProgressView(value: Double(storage.completed), total: Double(max(1, storage.total)))
                        .accessibilityLabel("Moving models")
                } footer: {
                    if storage.total > 0 {
                        Text(storage.filename).lineLimit(1).truncationMode(.middle)
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.completed), countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: Int64(clamping: storage.total), countStyle: .file))")
                    } else {
                        Text("Preparing to move models…")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
        } actions: {
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 12)
        .frame(width: 460, height: 220)
    }
}

/// Download surfaces expose the saved destination; editing belongs exclusively to Settings.
public struct ModelStorageDestination: View {
    @Bindable private var storage: ModelStorage
    @Environment(\.openSettings) private var openSettings
    public init(storage: ModelStorage) { self.storage = storage }
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Saving to") {
                HStack {
                    if let info = storage.info {
                        Label(NSString(string: info.directory).abbreviatingWithTildeInPath, systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle).help(info.directory)
                    } else { ProgressView().controlSize(.small) }
                    Button("Change…") {
                        storage.settingsRequestID = UUID()
                        openSettings()
                    }
                    .help("Open Model Storage in Settings")
                    .accessibilityLabel("Open Model Storage Settings")
                }
            }
            if let error = storage.error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }
        .task { await storage.refresh() }
    }
}
