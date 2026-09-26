import SwiftUI

public struct ProviderConnectionPresentation {
  public var baseURLTitle: String
  public var baseURLPrompt: String
  public var baseURLHelp: String
  public var apiKeyTitle: String
  public var apiKeyHelp: String
  public var hasStoredAPIKey: Bool
  public var isAPIKeyVisible: Bool
  public var apiKeyVisibilityButtonTitle: String
  public var canToggleAPIKeyVisibility: Bool
  public var modelCount: Int
  public var isDiscovering: Bool
  public var showsDefaultToggle: Bool

  public init(
    baseURLTitle: String, baseURLPrompt: String, baseURLHelp: String, apiKeyTitle: String,
    apiKeyHelp: String, hasStoredAPIKey: Bool, isAPIKeyVisible: Bool,
    apiKeyVisibilityButtonTitle: String, canToggleAPIKeyVisibility: Bool, modelCount: Int,
    isDiscovering: Bool, showsDefaultToggle: Bool
  ) {
    self.baseURLTitle = baseURLTitle
    self.baseURLPrompt = baseURLPrompt
    self.baseURLHelp = baseURLHelp
    self.apiKeyTitle = apiKeyTitle
    self.apiKeyHelp = apiKeyHelp
    self.hasStoredAPIKey = hasStoredAPIKey
    self.isAPIKeyVisible = isAPIKeyVisible
    self.apiKeyVisibilityButtonTitle = apiKeyVisibilityButtonTitle
    self.canToggleAPIKeyVisibility = canToggleAPIKeyVisibility
    self.modelCount = modelCount
    self.isDiscovering = isDiscovering
    self.showsDefaultToggle = showsDefaultToggle
  }
}

/// Credential storage and reveal policy remain with the host. Values are never persisted here.
public struct ProviderConnectionSection<Feedback: View>: View {
  @Binding var baseURL: String
  @Binding var apiKey: String
  @Binding var makeDefault: Bool
  let presentation: ProviderConnectionPresentation
  let toggleAPIKeyVisibility: () -> Void
  let refresh: () -> Void
  let feedback: Feedback

  public init(
    baseURL: Binding<String>, apiKey: Binding<String>, makeDefault: Binding<Bool>,
    presentation: ProviderConnectionPresentation,
    toggleAPIKeyVisibility: @escaping () -> Void, refresh: @escaping () -> Void,
    @ViewBuilder feedback: () -> Feedback
  ) {
    _baseURL = baseURL
    _apiKey = apiKey
    _makeDefault = makeDefault
    self.presentation = presentation
    self.toggleAPIKeyVisibility = toggleAPIKeyVisibility
    self.refresh = refresh
    self.feedback = feedback()
  }

  public var body: some View {
    Section {
      LabeledContent {
        TextField(
          presentation.baseURLTitle,
          text: $baseURL,
          prompt: Text(presentation.baseURLPrompt)
        )
        .labelsHidden()
      } label: {
        ProviderFieldLabel(
          title: presentation.baseURLTitle,
          help: presentation.baseURLHelp
        )
      }

      LabeledContent {
        HStack(spacing: 8) {
          if presentation.isAPIKeyVisible {
            TextField(
              presentation.apiKeyTitle,
              text: $apiKey,
              prompt: Text(presentation.hasStoredAPIKey ? "Saved in Keychain" : "Enter API key")
            )
            .labelsHidden()
            .accessibilityLabel(presentation.apiKeyTitle)
            .privacySensitive()
          } else {
            SecureField(
              presentation.apiKeyTitle,
              text: $apiKey,
              prompt: Text(presentation.hasStoredAPIKey ? "Saved in Keychain" : "Enter API key")
            )
            .labelsHidden()
            .accessibilityLabel(presentation.apiKeyTitle)
            .privacySensitive()
          }

          Button(
            presentation.apiKeyVisibilityButtonTitle,
            systemImage: presentation.isAPIKeyVisible ? "eye.slash" : "eye",
            action: toggleAPIKeyVisibility
          )
          .labelStyle(.iconOnly)
          .buttonStyle(FritzButtonStyle())
          .frame(width: 24, height: 20)
          .help(presentation.apiKeyVisibilityButtonTitle)
          .disabled(!presentation.canToggleAPIKeyVisibility)
        }
      } label: {
        ProviderFieldLabel(title: presentation.apiKeyTitle, help: presentation.apiKeyHelp)
      }

      LabeledContent("Models") {
        HStack(spacing: 8) {
          Text(presentation.isDiscovering ? "Loading…" : "\(presentation.modelCount) available")
            .foregroundStyle(.secondary)

          Button("Refresh Models", systemImage: "arrow.clockwise", action: refresh)
            .labelStyle(.iconOnly)
            .buttonStyle(FritzButtonStyle())
            .frame(width: 24, height: 20)
            .help("Refresh Models")
            .disabled(presentation.isDiscovering)
            .opacity(presentation.isDiscovering ? 0 : 1)
            .accessibilityHidden(presentation.isDiscovering)
            .overlay {
              if presentation.isDiscovering {
                ProgressView()
                  .controlSize(.small)
                  .accessibilityLabel("Loading models")
              }
            }
        }
        .frame(minHeight: 20)
      }

      if presentation.showsDefaultToggle {
        Toggle("Use as Default Provider", isOn: $makeDefault)
      }
    } footer: {
      feedback
    }
  }
}

private struct ProviderFieldLabel: View {
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
