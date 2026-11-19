import FritzUI
import SwiftUI
import Combine

struct ProjectsSidebar: View {
    @Bindable var workspace: WorkspaceStore
    @State private var renaming: RenameItem?
    @State private var deleting: ProjectThread?
    @State private var deletingProject: FritzProject?

    var body: some View {
        List(selection: Binding(get: { workspace.selectedThreadID }, set: { id in Task { await workspace.select(id) } })) {
            if !workspace.projects.isEmpty {
                Section("Projects") {
                    ForEach(workspace.sidebarProjects) { project in
                        let isAvailable = workspace.isAvailable(project)
                        DisclosureGroup(isExpanded: Binding(
                            get: { workspace.expandedProjectID == project.id },
                            set: { expanded in Task { await workspace.expand(project.id, expanded: expanded) } }
                        )) {
                            ForEach(workspace.expandedProjectID == project.id ? workspace.sidebarThreads : []) { thread in
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
                                    Button("Archive Thread", systemImage: "archivebox") {
                                        Task { await workspace.setArchived(thread.id, true) }
                                    }
                                    Button("New Chat", systemImage: "square.and.pencil") {
                                        Task { await workspace.createThread(in: project.id) }
                                    }.disabled(!isAvailable)
                                    Divider()
                                    Button("Delete Thread…", systemImage: "trash", role: .destructive) { deleting = thread }
                                }
                            }
                            if workspace.expandedProjectID == project.id {
                                pageControls(label: "Threads", previous: workspace.threadCursors.count > 1,
                                             next: workspace.hasMoreThreads, page: workspace.pageThreads)
                            }
                        } label: {
                            Label(project.name, systemImage: "folder")
                                .lineLimit(1).help(project.directory ?? project.name)
                                .foregroundStyle(isAvailable ? .primary : .secondary)
                            .contextMenu {
                                Button("New Chat", systemImage: "square.and.pencil") {
                                    Task { await workspace.createThread(in: project.id) }
                                }.disabled(!isAvailable)
                                Button("Rename Project", systemImage: "pencil") {
                                    renaming = RenameItem(id: project.id, title: project.name, isProject: true)
                                }
                                if !isAvailable {
                                    Divider()
                                    Button("Recreate Folder") { repair(project) }
                                    Button("Choose Another Folder…") { chooseReplacement(for: project) }
                                } else if let directory = project.directory {
                                    Button("Show in Finder", systemImage: "folder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)])
                                    }
                                }
                                Divider()
                                Button("Delete Project…", systemImage: "trash", role: .destructive) {
                                    deletingProject = project
                                }
                                .disabled(workspace.isEditing)
                            }
                        }

                    }
                    pageControls(label: "Projects", previous: workspace.projectCursors.count > 1,
                                 next: workspace.hasMoreProjects, page: workspace.pageProjects)
                }
            }
        }
        .listStyle(.sidebar)
        .task { await workspace.restore() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in Task { await workspace.refreshAvailability() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await workspace.refreshAvailability() }
        }
        .confirmationDialog("Delete Thread?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { thread in
            Button("Delete Thread", role: .destructive) { Task { await workspace.deleteThread(thread.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { thread in
            Text("“\(thread.title)” and its messages will be permanently deleted.")
        }
        .alert("Delete Project?", isPresented: Binding(
            get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }
        ), presenting: deletingProject) { project in
            Button("Delete Project", role: .destructive) { Task { await workspace.deleteProject(project.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { project in
            Text("“\(project.name)” and all its chats and drafts will be permanently deleted from Fritz. The project folder and its files will stay on disk.")
        }
        .sheet(item: $renaming) { item in
            RenameItemSheet(item: item) { name in
                Task {
                    if item.isProject { await workspace.renameProject(item.id, to: name) }
                    else { await workspace.renameThread(item.id, to: name) }
                }
            }
        }
    }

    @ViewBuilder private func pageControls(label: String, previous: Bool, next: Bool,
                                          page: @escaping (Bool) async -> Void) -> some View {
        if previous || next {
            HStack {
                if previous {
                    Button { Task { await page(false) } } label: { Label("Previous \(label)", systemImage: "chevron.left") }
                }
                if next {
                    Button { Task { await page(true) } } label: { Label("More \(label)", systemImage: "chevron.right") }
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(workspace.isEditing)
        }
    }

    private func repair(_ project: FritzProject, directory: URL? = nil) {
        Task { await workspace.repairProject(project.id, directory: directory) }
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

struct RenameItem: Identifiable {
    let id: UUID
    let title: String
    let isProject: Bool
}

struct RenameItemSheet: View {
    let item: RenameItem
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        FritzDialog(item.isProject ? "Rename Project" : "Rename Thread") {
            TextField("Name", text: $name)
                .padding(.horizontal, 24)
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { save(name); dismiss() }.keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 12)
        .frame(width: 380)
        .presentationSizing(.fitted)
        .onAppear { name = item.title }
    }
}

struct NewProjectSheet: View {
    let workspace: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var directory: URL?
    @State private var error: String?

    var body: some View {
        FritzDialog("New Project") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Name").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Name", text: $name, prompt: Text("Project name"))
                            .labelsHidden()
                    }
                    GridRow {
                        Text("Folder").foregroundStyle(.secondary)
                        HStack {
                            Text((directory ?? WorkspaceStore.defaultProjectDirectory(name: name)).abbreviatedPath)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .help((directory ?? WorkspaceStore.defaultProjectDirectory(name: name)).path)
                            if directory != nil { Button("Use Default") { directory = nil } }
                            Button("Choose…", action: chooseFolder)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .padding(.horizontal, 24)
        } actions: {
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Create Project", action: create).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !workspace.canSave || workspace.isEditing)
        }
        .padding(.vertical, 12)
        .frame(width: 460)
        .presentationSizing(.fitted)
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
        Task {
            do { try await workspace.createProject(name: name, directory: directory); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension URL {
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
