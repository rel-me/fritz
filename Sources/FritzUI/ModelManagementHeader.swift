import SwiftUI

/// Heading and action area shared by model-management pages. The host supplies
/// its workspace color and actions while the layout stays consistent.
public struct ModelManagementHeader<Actions: View>: View {
  let title: String
  let description: String?
  let background: Color
  @ViewBuilder let actions: Actions

  public init(
    _ title: String, description: String? = nil, background: Color,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.description = description
    self.background = background
    self.actions = actions()
  }

  public var body: some View {
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
    .background(background)
  }
}
