import SwiftUI

/// Window-attached model editor with native form controls.
public struct ModelProviderEditor<Content: View>: View {
    let title: String
    let primaryActionTitle: String
    let canSave: Bool
    let isSaving: Bool
    let width: CGFloat
    let height: CGFloat
    let cancel: () -> Void
    let save: () -> Void
    let downloadModels: (() -> Void)?
    let modelStorage: ModelStorage?
    let isInstalling: Bool
    let content: Content

    public init(
        title: String, primaryActionTitle: String, canSave: Bool, isSaving: Bool = false,
        width: CGFloat = 600, height: CGFloat,
        cancel: @escaping () -> Void, save: @escaping () -> Void,
        downloadModels: (() -> Void)? = nil,
        modelStorage: ModelStorage? = nil,
        isInstalling: Bool = false, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.primaryActionTitle = primaryActionTitle
        self.canSave = canSave
        self.isSaving = isSaving
        self.width = width
        self.height = height
        self.cancel = cancel
        self.save = save
        self.downloadModels = downloadModels
        self.modelStorage = modelStorage
        self.isInstalling = isInstalling
        self.content = content()
    }

    public var body: some View {
        FritzDialog(title) {
            VStack(spacing: 0) {
                content
                if modelStorage != nil || downloadModels != nil {
                    HStack {
                        if let modelStorage {
                            ModelStorageDestination(storage: modelStorage)
                                .disabled(isSaving || isInstalling)
                                .layoutPriority(-1)
                        }
                        if let downloadModels {
                            Button("Download Models", action: downloadModels).disabled(isSaving)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                }
            }
        } actions: {
            if isSaving {
                ProgressView().controlSize(.small).accessibilityLabel("Saving model")
                Spacer()
            }
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
            Button(primaryActionTitle, action: save)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSaving)
        }
        .padding(.vertical, 12)
        .frame(width: width, height: height)
    }
}
