import SwiftUI

public struct ModelProviderItem<ID: Hashable>: Identifiable {
  public let id: ID
  public let name: String
  public let warning: String?
  public let isLocal: Bool
  public let isDefault: Bool
  public let models: String?

  public init(
    id: ID, name: String, warning: String?, isLocal: Bool, isDefault: Bool, models: String?
  ) {
    self.id = id
    self.name = name
    self.warning = warning
    self.isLocal = isLocal
    self.isDefault = isDefault
    self.models = models
  }
}

/// Native multi-selection table. Attach host context menus and keyboard commands to this view.
public struct ModelProvidersTable<ID: Hashable>: View {
  let providers: [ModelProviderItem<ID>]
  @Binding var selection: Set<ID>
  let isLoading: Bool
  let edit: (ID) -> Void

  public init(
    providers: [ModelProviderItem<ID>], selection: Binding<Set<ID>>,
    isLoading: Bool, edit: @escaping (ID) -> Void
  ) {
    self.providers = providers
    _selection = selection
    self.isLoading = isLoading
    self.edit = edit
  }

  public var body: some View {
    Table(providers, selection: $selection) {
      TableColumn("Name") { profile in
        HStack(spacing: 6) {
          Text(profile.name)
            .lineLimit(1)
            .truncationMode(.tail)
          if let warning = profile.warning {
            Button {
              edit(profile.id)
            } label: {
              providerChip("Needs Setup", color: .orange)
            }
            .buttonStyle(FritzButtonStyle(.inline))
            .help(warning)
            .accessibilityLabel("\(profile.name): \(warning)")
          } else {
            providerChip("Ready", color: .green)
          }
          if profile.isLocal {
            providerChip("Local")
          }
          if profile.isDefault {
            providerChip("Default")
          }
        }
      }
      .width(min: 240, max: .infinity)

      TableColumn("Models") { profile in
        if let names = profile.models {
          Text(names)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(names)
        } else {
          Text(isLoading ? "Loading…" : "—")
            .foregroundStyle(.secondary)
        }
      }
      .width(min: 70, max: .infinity)
    }
  }

  private func providerChip(_ title: String, color: Color = .secondary) -> some View {
    Text(title)
      .font(.caption)
      .foregroundStyle(color)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.12), in: Capsule())
      .fixedSize()
  }

}
