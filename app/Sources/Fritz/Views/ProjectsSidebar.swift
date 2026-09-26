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
                                    Button("New Thread", systemImage: "square.and.pencil") { workspace.createThread(in: project.id) }
                                }
                            }
                        } label: {
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1).help(project.directory ?? project.name)
                        }
                        .contextMenu {
                            Button("New Thread", systemImage: "square.and.pencil") {
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
            RenameItemSheet(item: item) { name in
                if item.isProject { workspace.renameProject(item.id, to: name) }
                else { workspace.renameThread(item.id, to: name) }
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
            Text(item.isProject ? "Rename Project" : "Rename Thread").font(.headline)
            TextField("Name", text: $name)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(width: 380).onAppear { name = item.title }
    }
}

struct NewProjectSheet: View {
    let workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            FritzManagementHeader("New Project", description: "Choose a folder and start a thread.")
            Form {
                TextField("Name", text: $name, prompt: Text("Project name"))
                LabeledContent("Folder") {
                    HStack {
                        Text(directory?.abbreviatedPath ?? "Choose a project folder")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }.fritzSettingsFormStyle()
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Project", action: create)
                    .buttonStyle(FritzButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(directory == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workspace.canSave)
            }
            .padding(16)
            .background(FritzWindowStyle.workspaceBackground)
        }.frame(width: 540, height: 280)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Project Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
    private func create() {
        guard let directory else { return }
        do { try workspace.createProject(name: name, directory: directory); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
