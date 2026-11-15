import SwiftUI

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
