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
            .sheet(item: $editor) {
                ModelsProviderEditor(store: store, localModels: runtime, existing: $0.connection, initialPreset: $0.preset)
            }
            .task { await store.refresh(); await runtime.refresh() }
    }
}
