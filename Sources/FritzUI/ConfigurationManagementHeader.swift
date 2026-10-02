import SwiftUI

/// Compact heading shared by the standalone management windows.
struct ConfigurationManagementHeader<Actions: View>: View {
    let title: String
    let description: String?
    @ViewBuilder var actions: Actions

    init(_ title: String, description: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                if let description {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
                .fixedSize()
                .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(ModelsConfigurationStyle.workspaceBackground)
    }
}

extension ConfigurationManagementHeader where Actions == EmptyView {
    init(_ title: String, description: String? = nil) {
        self.init(title, description: description) { EmptyView() }
    }
}

// Apply at the Form itself so standalone settings and embedded pages agree.
extension View {
    func fritzSettingsFormStyle(background: Color = ModelsConfigurationStyle.contentBackground) -> some View {
        formStyle(.grouped)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(background)
    }
}
