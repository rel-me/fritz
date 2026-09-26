import AppKit
import SwiftUI

struct ProviderTextExport: Identifiable {
    let id = UUID()
    let text: String
    let includesKeys: Bool
}

struct ProviderTransferSheet: View {
    let store: ProviderStore
    var exported: ProviderTextExport?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var policy = ExistingProviderImportPolicy.skip
    @State private var error: String?
    @State private var copied = false
    @State private var isImporting = false
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exported == nil ? "Import Providers" : "Export Providers").font(.title2.bold())
            Text(guidance).font(.callout).foregroundStyle(.secondary)
            if let exported {
                ScrollView {
                    Text(exported.text)
                        .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
                }
                .border(.separator)
                .accessibilityLabel("Exported configuration")
                .privacySensitive(exported.includesKeys)
            } else {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced)).border(.separator)
                    .accessibilityLabel("Configuration to import").privacySensitive()
                    .disabled(isImporting)
                Picker("Existing providers", selection: $policy) {
                    Text("Skip").tag(ExistingProviderImportPolicy.skip)
                    Text("Overwrite").tag(ExistingProviderImportPolicy.overwrite)
                }.pickerStyle(.segmented).disabled(isImporting)
                Text("Matches the service name. Overwrite keeps saved keys when no key is included and the endpoint is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if let exported {
                    Button(copied ? "Copied" : "Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(exported.text, forType: .string)
                    }
                } else {
                    Button("Paste", systemImage: "doc.on.clipboard") {
                        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
                            error = "Copy a configuration first, then paste it here."
                            return
                        }
                        guard value.utf8.count <= ProviderConfigurationTransfer.maximumBytes else {
                            error = "The configuration must be no larger than 1 MB."
                            return
                        }
                        text = value; error = nil
                    }.disabled(isImporting)
                }
                Spacer()
                if isImporting { ProgressView().controlSize(.small) }
                Button(exported == nil ? "Cancel" : "Done") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isImporting)
                if exported == nil {
                    Button("Import", action: importProviders)
                        .buttonStyle(FritzButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                        .disabled(isImporting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(24).frame(width: 600, height: exported == nil ? 460 : 350)
        .background(FritzWindowStyle.contentBackground)
        .interactiveDismissDisabled(isImporting)
        .buttonStyle(FritzButtonStyle())
        .onDisappear { importTask?.cancel() }
    }

    private var guidance: String {
        guard let exported else {
            return "Paste a Fritz or REL provider configuration. Included API keys are saved in Keychain. Providers without keys can be completed later."
        }
        return exported.includesKeys
            ? "This JSON includes API keys. Share it only with people who should have access."
            : "Copy this JSON. API keys and the default-provider preference are excluded."
    }

    private func importProviders() {
        isImporting = true; error = nil
        importTask = Task {
            defer { isImporting = false; importTask = nil }
            do {
                try await store.importProviders(text, policy: policy)
                try Task.checkCancellation()
                text = ""; dismiss()
            } catch is CancellationError {
            } catch { self.error = error.localizedDescription }
        }
    }
}
