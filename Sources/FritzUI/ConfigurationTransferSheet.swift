import AppKit
import Fritz
import SwiftUI

struct ProviderTextExport: Identifiable {
    let id = UUID()
    let text: String
    let includesKeys: Bool
}

struct ConfigurationTransferSheet<Store: ModelsProviderStore>: View {
    let store: Store
    var exported: ProviderTextExport?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var overwritesExisting = true
    @State private var error: String?
    @State private var copied = false
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        FritzDialog(exported == nil ? "Import Models" : "Export Models") {
            Form {
                Section {
                    if let exported {
                        ScrollView {
                            Text(exported.text)
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                        .frame(minHeight: 130)
                        .accessibilityLabel("Exported cURL")
                        .privacySensitive(exported.includesKeys)
                    } else {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                            .accessibilityLabel("cURL to import").privacySensitive()
                            .disabled(isImporting)
                    }
                } footer: {
                    Text(guidance)
                    if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                if exported == nil {
                    Section {
                        Toggle("Overwrite existing", isOn: $overwritesExisting)
                            .toggleStyle(.checkbox).disabled(isImporting)
                    } footer: {
                        Text("Matches the service name. Overwrite keeps saved keys when no key is included and the endpoint is unchanged.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
        } actions: {
            if isImporting {
                ProgressView().controlSize(.small).accessibilityLabel("Importing models")
            }
            transferAction
            Spacer()
            Button(exported == nil ? "Cancel" : "Done") { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(isImporting)
            if exported == nil {
                Button("Import", action: importProviders).keyboardShortcut(.defaultAction)
                    .disabled(isImporting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 600, height: exported == nil ? 480 : 350)
        .interactiveDismissDisabled(isImporting)
        .onDisappear { importTask?.cancel() }
    }

    @ViewBuilder private var transferAction: some View {
        if let exported {
            Button(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                copied = NSPasteboard.general.setString(exported.text, forType: .string)
            }
        } else {
            Button("Paste", systemImage: "doc.on.clipboard") {
                guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
                    error = "Copy a cURL request first, then paste it here."
                    return
                }
                guard value.utf8.count <= 1_048_576 else {
                    error = "The configuration must be no larger than 1 MB."
                    return
                }
                text = value; error = nil
            }.disabled(isImporting)
        }
    }

    private var guidance: String {
        guard let exported else {
            return "Paste a cURL provider export. Included API keys are saved in Keychain. Providers without keys can be completed later."
        }
        return exported.includesKeys
            ? "This export includes API keys. Share it only with people who should have access."
            : "Checks the provider’s model list. Required API keys are replaced with YOUR_API_KEY."
    }

    private func importProviders() {
        isImporting = true; error = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                try await store.importProviders(text, policy: overwritesExisting ? .overwrite : .skip)
                try Task.checkCancellation()
                text = ""; dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
