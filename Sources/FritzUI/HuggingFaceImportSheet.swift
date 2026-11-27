import Fritz
import Foundation
import Observation
import SwiftUI

struct HuggingFaceRepository: Decodable, Sendable {
    struct File: Decodable, Identifiable, Sendable {
        let path: String
        let size: UInt64
        let id: String

        var sizeLabel: String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
        }
    }

    let repository: String
    let url: URL
    let revision: String
    let files: [File]
}

@MainActor @Observable final class HuggingFaceImport {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            repository = nil
            selectedPath = ""
            error = nil
        }
    }
    var selectedPath = ""
    private(set) var repository: HuggingFaceRepository?
    private(set) var isLookingUp = false
    private(set) var error: String?
    private(set) var transfer: ModelTransfer?

    var selectedFile: HuggingFaceRepository.File? {
        repository?.files.first { $0.path == selectedPath }
    }

    func lookup(using store: ModelsStore) async {
        guard !isLookingUp else { return }
        isLookingUp = true
        error = nil
        defer { isLookingUp = false }
        let input = query
        do {
            let result: HuggingFaceRepository = try await store.agent.request(
                "localModels.huggingFaceLookup", params: ["repository": input]
            )
            guard input == query else { return }
            repository = result
            selectedPath = result.files.first?.path ?? ""
            select(using: store)
        } catch {
            guard input == query else { return }
            self.error = error.localizedDescription
        }
    }

    func select(using store: ModelsStore) {
        transfer = selectedFile.flatMap { store.modelDownloads[$0.id] }
    }

    func download(using store: ModelsStore) {
        guard let repository, let file = selectedFile else { return }
        let transfer = store.modelDownloads.transfer(for: file, repository: repository, store: store)
        self.transfer = transfer
        _ = transfer.install()
    }
}

struct HuggingFaceImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let store: ModelsStore

    var body: some View {
        @Bindable var importer = store.huggingFaceImport
        let transfer = importer.transfer
        let isDownloading = transfer?.isDownloading == true

        FritzDialog("Import from Hugging Face", separatesActions: true) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    TextField("Repository", text: $importer.query, prompt: Text("owner/model or repository URL"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(isDownloading || importer.isLookingUp)
                        .onSubmit { lookUp() }
                    Button("Find GGUF Files", action: lookUp)
                        .disabled(isDownloading || importer.isLookingUp || importer.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if importer.isLookingUp {
                    ProgressView("Looking up repository…").controlSize(.small)
                }
                if let error = importer.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                if let repository = importer.repository {
                    Picker("GGUF file", selection: $importer.selectedPath) {
                        ForEach(repository.files, id: \.path) { file in
                            Text("\(file.path) · \(file.sizeLabel)").tag(file.path)
                        }
                    }
                    .disabled(isDownloading)
                    .onChange(of: importer.selectedPath) { importer.select(using: store) }
                    ModelStorageDestination(storage: store.modelStorage)
                        .disabled(isDownloading)
                    switch transfer?.state {
                    case .installed:
                        Label("Imported", systemImage: "checkmark.circle")
                    case .checking:
                        ProgressView("Preparing download…").progressViewStyle(.linear)
                    case let .downloading(downloaded, total, bytesPerSecond):
                        ModelDownloadProgress(downloaded: downloaded, total: total,
                                              bytesPerSecond: bytesPerSecond, showsTitle: true)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red).textSelection(.enabled)
                    default:
                        EmptyView()
                    }
                    if isDownloading {
                        Button("Stop Download") { transfer?.stopDownload() }
                    } else if transfer?.state != .installed {
                        Button("Download and Import") { importer.download(using: store) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(store.modelStorage.isBusy || importer.selectedFile == nil)
                    }
                }
            }
            .padding(.horizontal, 24)
        } actions: {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.top, 12)
        .frame(width: 560)
        .fritzFittedSheet()
    }

    private func lookUp() {
        Task { await store.huggingFaceImport.lookup(using: store) }
    }
}
