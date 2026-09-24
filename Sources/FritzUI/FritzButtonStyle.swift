import SwiftUI

/// Choose by placement, not by appearance. Content and cell actions use regular
/// controls; management header actions, floating controls, and the chat Send/Stop
/// action opt into Liquid Glass.
/// Keep native roles, focus, keyboard activation, tint and disabled rendering.
public struct FritzButtonStyle: PrimitiveButtonStyle {
  @Environment(\.controlSize) private var inheritedSize
  @Environment(\.fritzButtonControlSize) private var preferredSize
  public enum Context {
    case content
    case primary
    case floating
    case floatingPrimary
    case inline
    case link
    case panel
    case toolbar
  }

  var context: Context = .content
  var size: ControlSize?
  var shape: ButtonBorderShape

  public init(
    _ context: Context = .content, size: ControlSize? = nil, shape: ButtonBorderShape = .capsule
  ) {
    self.context = context
    self.size = size
    self.shape = shape
  }

  private var controlSize: ControlSize {
    if let size { return size }
    if inheritedSize != .regular { return inheritedSize }
    return preferredSize ?? .regular
  }

  @ViewBuilder
  public func makeBody(configuration: Configuration) -> some View {
    switch context {
    case .content:
      button(configuration).buttonStyle(.bordered).controlSize(controlSize)
    case .primary:
      button(configuration).buttonStyle(.borderedProminent).controlSize(controlSize)
    case .floating:
      if #available(macOS 26.0, *) {
        button(configuration).buttonStyle(.glass).buttonBorderShape(shape).controlSize(controlSize)
      } else {
        button(configuration).buttonStyle(.bordered).controlSize(controlSize)
      }
    case .floatingPrimary:
      if #available(macOS 26.0, *) {
        button(configuration).buttonStyle(.glassProminent).buttonBorderShape(shape).controlSize(
          controlSize)
      } else {
        button(configuration).buttonStyle(.borderedProminent).controlSize(controlSize)
      }
    case .inline:
      button(configuration).buttonStyle(.plain)
    case .link:
      button(configuration).buttonStyle(.link)
    case .panel:
      button(configuration).buttonStyle(.borderless).controlSize(controlSize)
    case .toolbar:
      button(configuration).buttonStyle(.automatic)
    }
  }

  private func button(_ configuration: Configuration) -> some View {
    Button(role: configuration.role, action: configuration.trigger) {
      configuration.label
    }
  }
}

private struct FritzButtonControlSizeKey: EnvironmentKey {
  static let defaultValue: ControlSize? = nil
}

extension EnvironmentValues {
  fileprivate var fritzButtonControlSize: ControlSize? {
    get { self[FritzButtonControlSizeKey.self] }
    set { self[FritzButtonControlSizeKey.self] = newValue }
  }
}

extension View {
  /// Keep cell buttons compact without resizing the cell's other controls.
  public func fritzButtonSize(_ size: ControlSize) -> some View {
    environment(\.fritzButtonControlSize, size)
  }
}

public struct FritzGlassControlGroup: ViewModifier {
  public init() {}
  @ViewBuilder
  public func body(content: Content) -> some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: 6) {
        content
      }
    } else {
      content
    }
  }
}

/// Common panel utility controls keep native hover, keyboard focus, and disabled rendering.
public struct FritzPanelIconControl: ViewModifier {
  var isEmphasized: Bool

  public init(isEmphasized: Bool = false) { self.isEmphasized = isEmphasized }

  public func body(content: Content) -> some View {
    content
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .foregroundStyle(isEmphasized ? .primary : .secondary)
      .frame(width: 24, height: 24)
      .contentShape(Rectangle())
  }
}
