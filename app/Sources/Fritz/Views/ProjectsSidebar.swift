import SwiftUI
import Combine

struct ProjectsSidebar: View {
    @Bindable var workspace: WorkspaceStore
    @State private var collapsedProjects: Set<UUID> = []
    @State private var renaming: RenameItem?
    @State private var deleting: ProjectThread?
    @State private var repairing: FritzProject?
    @State private var showArchived = false

    var body: some View {
        List(selection: Binding(get: { workspace.selectedThreadID }, set: { workspace.select($0) })) {
            if !workspace.projects.isEmpty {
                Section("Projects") {
                    ForEach(workspace.projects) { project in
                        DisclosureGroup(isExpanded: Binding(
                            get: { !collapsedProjects.contains(project.id) },
                            set: { if $0 { collapsedProjects.remove(project.id) } else { collapsedProjects.insert(project.id) } }
                        )) {
                            ForEach(project.threads.filter { showArchived || !$0.isArchived }) { thread in
                                HStack(spacing: 7) {
                                    Label(thread.title, systemImage: thread.isArchived ? "archivebox" : "bubble.left")
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                                .tag(thread.id)
                                .help(thread.title)
                                .contextMenu {
                                    Button("Rename Thread", systemImage: "pencil") {
                                        renaming = RenameItem(id: thread.id, title: thread.title, isProject: false)
                                    }
                                    Button(thread.isArchived ? "Restore Thread" : "Archive Thread", systemImage: "archivebox") {
                                        workspace.setArchived(thread.id, !thread.isArchived)
                                    }
                                    Button("New Chat", systemImage: "square.and.pencil") { workspace.createThread(in: project.id) }
                                    Divider()
                                    Button("Delete Thread…", systemImage: "trash", role: .destructive) { deleting = thread }
                                }
                                .disabled(!workspace.isAvailable(project))
                            }
                        } label: {
                            HStack {
                                Label(project.name, systemImage: "folder")
                                    .lineLimit(1).help(project.directory ?? project.name)
                                    .foregroundStyle(workspace.isAvailable(project) ? .primary : .secondary)

                            }
                            .contextMenu {
                                Button("New Chat", systemImage: "square.and.pencil") {
                                    collapsedProjects.remove(project.id)
                                    workspace.createThread(in: project.id)
                                }.disabled(!workspace.isAvailable(project))
                                Button("Rename Project", systemImage: "pencil") {
                                    renaming = RenameItem(id: project.id, title: project.name, isProject: true)
                                }
                                if let directory = project.directory {
                                    Button("Show in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
                                    }.disabled(!workspace.isAvailable(project))
                                }
                            }
                        }

                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { if workspace.selectedThread?.isArchived == true { showArchived = true } }
        .onChange(of: showArchived) { _, showing in
            if !showing && workspace.selectedThread?.isArchived == true { workspace.clearSelection() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in workspace.refreshAvailability() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            workspace.refreshAvailability()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(workspace.projects.filter { !workspace.isAvailable($0) }) { project in
                    HStack {
                        Label(project.name, systemImage: "folder.badge.questionmark")
                            .lineLimit(1).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button("Fix") { repairing = project }
                            .controlSize(.small)
                            .help("Fix the unavailable folder for \(project.name)")
                    }
                    .font(.caption)
                }
                if workspace.projects.contains(where: { $0.threads.contains(where: \.isArchived) }) {
                    Toggle("Show Archived Threads", isOn: $showArchived)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            }
            .padding(workspace.projects.contains(where: { !workspace.isAvailable($0) || $0.threads.contains(where: \.isArchived) }) ? 12 : 0)
        }
        .confirmationDialog("Fix Project Folder", isPresented: Binding(
            get: { repairing != nil }, set: { if !$0 { repairing = nil } }
        ), presenting: repairing) { project in
            Button("Recreate Folder") { repair(project) }
            Button("Choose Another Folder…") { chooseReplacement(for: project) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete Thread?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { thread in
            Button("Delete Thread", role: .destructive) { workspace.deleteThread(thread.id) }
            Button("Cancel", role: .cancel) {}
        } message: { thread in
            Text("“\(thread.title)” and its messages will be permanently deleted.")
        }
        .onChange(of: workspace.selectedProject?.id) { _, id in if let id { collapsedProjects.remove(id) } }
        .sheet(item: $renaming) { item in
            RenameItemSheet(item: item) { name in
                if item.isProject { workspace.renameProject(item.id, to: name) }
                else { workspace.renameThread(item.id, to: name) }
            }
        }
    }

    private func repair(_ project: FritzProject, directory: URL? = nil) {
        do { try workspace.repairProject(project.id, directory: directory) }
        catch { workspace.error = error.localizedDescription }
    }

    private func chooseReplacement(for project: FritzProject) {
        let panel = NSOpenPanel()
        panel.title = "Choose a Project Folder"
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { repair(project, directory: url) }
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
            FritzManagementHeader("New Project")
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
            }.fritzSettingsFormStyle()
            if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create Project", action: create)
                    .buttonStyle(FritzButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workspace.canSave)
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
        do { try workspace.createProject(name: name, directory: directory); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
