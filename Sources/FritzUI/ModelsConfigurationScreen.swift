import SwiftUI

/// The complete Models page, including the same editor used by Fritz's app.
public struct ModelsConfigurationScreen: View {
    @Bindable private var store: ModelsStore
    @Bindable private var runtime: ModelsLocalRuntime
    @State private var editor: ModelsEditorSelection?

    public init(store: ModelsStore, runtime: ModelsLocalRuntime) {
        self.store = store; self.runtime = runtime
    }

    public var body: some View {
        ModelsConfigurationView(store: store, localModels: runtime, editor: $editor)
            .sheet(item: $editor) { selection in
                NavigationStack { ModelsProviderEditor(store: store, localModels: runtime, existing: selection.connection, initialPreset: selection.preset) }
            }
            .task { await store.refresh(); await runtime.refresh() }
    }
}
