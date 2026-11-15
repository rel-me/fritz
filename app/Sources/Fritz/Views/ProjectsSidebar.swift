import SwiftUI

struct ProjectsSidebar: View {
    @Bindable var workspace: WorkspaceStore
    @State private var collapsedProjects: Set<UUID> = []
    @State private var renaming: RenameItem?

    var body: some View {
        List(selection: Binding(get: { workspace.selectedThreadID }, set: { workspace.select($0) })) {
            if !workspace.projects.isEmpty {
                Section("Projects") {
                    ForEach(workspace.projects) { project in
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsedProjects.contains(project.id) },
                            set: { if $0 { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) } }
                        )) {
                            ForEach(project.threads) { thread in
                                HStack(spacing: 7) {
                                    Label(thread.title, systemImage: "bubble.left")
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                                .tag(thread.id)
                                .help(thread.title)
                                .contextMenu {
                                    Button("Rename Thread", systemImage: "pencil") {
                                        renaming = RenameItem(id: thread.id, title: thread.title, isProject: false)
                                    }
                                    Button("New Chat", systemImage: "square.and.pencil") { workspace.createThread(in: project.id) }
                                }
                            }
                        } label: {
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1).help(project.directory ?? project.name)
                        }
                        .contextMenu {
                            Button("New Chat", systemImage: "square.and.pencil") {
                                collapsedProjects.remove(project.id)
                                workspace.createThread(in: project.id)
                            }
                            Button("Rename Project", systemImage: "pencil") {
                                renaming = RenameItem(id: project.id, title: project.name, isProject: true)
                            }
                            if let directory = project.directory {
                                Button("Show in Finder", systemImage: "folder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: workspace.selectedProject?.id) { _, id in if let id { collapsedProjects.remove(id) } }
        .sheet(item: $renaming) { item in
            NavigationStack {
                RenameItemSheet(item: item) { name in
                    if item.isProject { workspace.renameProject(item.id, to: name) }
                    else { workspace.renameThread(item.id, to: name) }
                }
            }
        }
    }
}

private struct RenameItem: Identifiable {
    let id: UUID
    let title: String
    let isProject: Bool
}

private struct RenameItemSheet: View {
    let item: RenameItem
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(item.isProject ? "Rename Project" : "Rename Thread")
        .padding(20).frame(width: 380).onAppear { name = item.title }
    }
}

struct NewProjectSheet: View {
    let workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory: URL?
    @State private var folderPanel: NSOpenPanel?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("Project name"))
                LabeledContent("Folder") {
                    HStack {
                        Text((directory ?? WorkspaceStore.defaultProjectDirectory(name: name)).abbreviatedPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .help((directory ?? WorkspaceStore.defaultProjectDirectory(name: name)).path)
                        if directory != nil { Button("Use Default") { directory = nil } }
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Project", action: create)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workspace.canSave)
            }
            .padding(16)
        }
        .navigationTitle("New Project")
        .frame(width: 540, height: 280)
        .onDisappear { folderPanel?.cancel(nil); folderPanel = nil }
    }

    private func chooseFolder() {
        guard folderPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.preventsApplicationTerminationWhenModal = false
        panel.title = "Choose a Project Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        folderPanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                directory = url
                if name.isEmpty { name = url.lastPathComponent }
            }
            folderPanel = nil
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
    private func create() {
        do { try workspace.createProject(name: name, directory: directory); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
