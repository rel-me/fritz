import SwiftUI

/// A display identity may differ from its adapter group (for example Bedrock
/// and generic OpenAI-compatible endpoints). IDs are supplied by the host.
public struct PickerProvider: Identifiable, Hashable, Sendable {
  public let id: String
  public let displayName: String
  public let groupID: String
  public init(id: String, displayName: String, groupID: String) {
    self.id = id
    self.displayName = displayName
    self.groupID = groupID
  }
}

public struct PickerBadge: Equatable, Sendable {
  public let systemImage: String
  public let help: String
  public let accessibilityLabel: String
  public init(systemImage: String, help: String, accessibilityLabel: String) {
    self.systemImage = systemImage
    self.help = help
    self.accessibilityLabel = accessibilityLabel
  }
}

/// Presentation data with the original host value returned on selection.
/// No persistence, provider protocols, or credential handling lives in FritzUI.
public struct ModelPickerItem<Value>: Identifiable {
  public let id: String
  public let value: Value
  public let displayName: String
  public let modelID: String
  public let displayProvider: PickerProvider
  public let sourceName: String?
  public let isRecommended: Bool
  public let badge: PickerBadge?
  public init(
    id: String, value: Value, displayName: String, modelID: String,
    provider: PickerProvider, sourceName: String? = nil,
    isRecommended: Bool = true, badge: PickerBadge? = nil
  ) {
    self.id = id
    self.value = value
    self.displayName = displayName
    self.modelID = modelID
    self.displayProvider = provider
    self.sourceName = sourceName
    self.isRecommended = isRecommended
    self.badge = badge
  }
}

public struct ProviderPickerItem<Value>: Identifiable {
  public let id: String
  public let value: Value
  public let name: String
  public let categoryIDs: Set<String>
  public let badgeText: String?
  public init(
    id: String, value: Value, name: String, categoryIDs: Set<String> = [], badgeText: String? = nil
  ) {
    self.id = id
    self.value = value
    self.name = name
    self.categoryIDs = categoryIDs
    self.badgeText = badgeText
  }
}

public struct PickerCategory: Identifiable, Hashable, Sendable {
  public let id: String
  public let title: String
  public let help: String
  public init(id: String, title: String, help: String) {
    self.id = id
    self.title = title
    self.help = help
  }
  public static let all = Self(id: "all", title: "All", help: "Show all providers")
}

public struct PickerStyle: Sendable {
  public var background: Color
  public var selectionFill: Color
  public var hoverFill: Color
  public var quietFill: Color
  public var border: Color
  public init(
    background: Color = Color(nsColor: .textBackgroundColor),
    selectionFill: Color = Color.primary.opacity(0.11),
    hoverFill: Color = Color.primary.opacity(0.055),
    quietFill: Color = Color.primary.opacity(0.035),
    border: Color = Color(nsColor: .separatorColor).opacity(0.72)
  ) {
    self.background = background
    self.selectionFill = selectionFill
    self.hoverFill = hoverFill
    self.quietFill = quietFill
    self.border = border
  }
}

private struct PickerStyleKey: EnvironmentKey { static let defaultValue = PickerStyle() }
extension EnvironmentValues {
  var fritzPickerStyle: PickerStyle {
    get { self[PickerStyleKey.self] }
    set { self[PickerStyleKey.self] = newValue }
  }
}
extension View {
  public func fritzPickerStyle(_ style: PickerStyle) -> some View {
    environment(\.fritzPickerStyle, style)
  }
}
