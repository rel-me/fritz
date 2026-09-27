import SwiftUI

struct IntegrationSettingsPageTitle<SectionHeader: View>: View {
  let title: String
  let description: String?
  let sectionHeader: SectionHeader

  init(
    _ title: String,
    description: String? = nil,
    @ViewBuilder sectionHeader: () -> SectionHeader
  ) {
    self.title = title
    self.description = description
    self.sectionHeader = sectionHeader()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
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

      sectionHeader
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(.primary)
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
  }
}

extension IntegrationSettingsPageTitle where SectionHeader == EmptyView {
  init(_ title: String, description: String? = nil) {
    self.init(title, description: description) {
      EmptyView()
    }
  }
}

struct IntegrationSettingsItemLabel: View {
  let title: String
  var help: String? = nil

  var body: some View {
    Text(title)
      .help(help ?? "")
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(title))
      .accessibilityHint(Text(help ?? ""))
  }
}
