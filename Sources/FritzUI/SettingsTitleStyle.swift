import SwiftUI

struct SettingsTitleStyle {
  var font: Font = .headline
  var bottomPadding: CGFloat = 0
}

private struct SettingsTitleStyleKey: EnvironmentKey {
  static let defaultValue = SettingsTitleStyle()
}

extension EnvironmentValues {
  var fritzSettingsTitleStyle: SettingsTitleStyle {
    get { self[SettingsTitleStyleKey.self] }
    set { self[SettingsTitleStyleKey.self] = newValue }
  }
}

extension View {
  /// Styles page titles in shared Settings forms and model-management headers.
  /// Section labels and control typography retain their native styles.
  public func fritzSettingsTitleStyle(font: Font, bottomPadding: CGFloat) -> some View {
    environment(\.fritzSettingsTitleStyle, SettingsTitleStyle(font: font, bottomPadding: bottomPadding))
  }
}
