import SwiftUI

/// Native model setup sheet with standard navigation, form content and actions.
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
    let downloadDirectory: URL?
    let chooseDownloadDirectory: ((URL) -> Void)?
    let isInstalling: Bool
    let content: Content

    public init(
        title: String, primaryActionTitle: String, canSave: Bool, isSaving: Bool = false,
        width: CGFloat = 600, height: CGFloat,
        cancel: @escaping () -> Void, save: @escaping () -> Void,
        downloadModels: (() -> Void)? = nil,
        downloadDirectory: URL? = nil, chooseDownloadDirectory: ((URL) -> Void)? = nil,
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
        self.downloadDirectory = downloadDirectory
        self.chooseDownloadDirectory = chooseDownloadDirectory
        self.isInstalling = isInstalling
        self.content = content()
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                content
                if chooseDownloadDirectory != nil || downloadModels != nil {
                    HStack {
                        if let chooseDownloadDirectory {
                            ConfigurationDownloadLocation(directory: downloadDirectory, choose: chooseDownloadDirectory)
                                .disabled(isSaving || isInstalling)
                                .layoutPriority(-1)
                        }
                        if let downloadModels {
                            Button("Download Models", action: downloadModels).disabled(isSaving)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding()
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(primaryActionTitle, action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave || isSaving)
                }
                ToolbarItem(placement: .status) {
                    if isSaving { ProgressView().controlSize(.small).accessibilityLabel("Saving model") }
                }
            }
        }
        .frame(width: width, height: height)
        .buttonStyle(.automatic)
    }
}
