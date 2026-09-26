import SwiftUI

/// Common provider sheet layout, license link, cancellation and primary action.
/// Hosts supply their heading and sections, including provider-specific extensions.
public struct ModelProviderEditor<Header: View, Content: View>: View {
  let primaryActionTitle: String
  let canSave: Bool
  let licenseURL: URL?
  let width: CGFloat
  let height: CGFloat
  let contentBackground: Color
  let footerBackground: Color
  let cancel: () -> Void
  let save: () -> Void
  let header: Header
  let content: Content

  public init(
    primaryActionTitle: String, canSave: Bool, licenseURL: URL? = nil,
    width: CGFloat = 600, height: CGFloat, contentBackground: Color, footerBackground: Color,
    cancel: @escaping () -> Void, save: @escaping () -> Void,
    @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content
  ) {
    self.primaryActionTitle = primaryActionTitle
    self.canSave = canSave
    self.licenseURL = licenseURL
    self.width = width
    self.height = height
    self.contentBackground = contentBackground
    self.footerBackground = footerBackground
    self.cancel = cancel
    self.save = save
    self.header = header()
    self.content = content()
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      HStack(spacing: 8) {
        if let licenseURL { Link("Model license", destination: licenseURL) }
        Spacer()
        Button("Cancel", action: cancel)
          .keyboardShortcut(.cancelAction)
        Button(primaryActionTitle, action: save)
          .buttonStyle(FritzButtonStyle(.primary))
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 12)
      .background(footerBackground)
    }
    .frame(width: width, height: height)
    .background(contentBackground)
  }
}
