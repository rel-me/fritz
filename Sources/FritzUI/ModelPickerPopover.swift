import SwiftUI

public struct ModelPickerPopover<Value>: View {
  @Environment(\.fritzPickerStyle) private var style
  let recommendationLimit: Int
  let models: [ModelPickerItem<Value>]
  let recentModels: [ModelPickerItem<Value>]
  let modelProviders: [String]
  let selectedModelID: String?
  let selectModel: (ModelPickerItem<Value>) -> Void
  let configureModels: () -> Void
  @State private var searchText = ""
  @State private var selectedProvider: PickerProvider?
  @State private var hoveredProviderFilterID: String?
  @FocusState private var isSearchFocused: Bool

  public init(
    models: [ModelPickerItem<Value>],
    recentModels: [ModelPickerItem<Value>],
    modelProviders: [String],
    selectedModelID: String?,
    selectModel: @escaping (ModelPickerItem<Value>) -> Void,
    configureModels: @escaping () -> Void,
    recommendationLimit: Int = 8,
    initialSearchText: String = ""
  ) {
    self.recommendationLimit = recommendationLimit
    self.models = models
    self.recentModels = recentModels
    self.modelProviders = modelProviders
    self.selectedModelID = selectedModelID
    self.selectModel = selectModel
    self.configureModels = configureModels
    _searchText = State(initialValue: initialSearchText)
  }

  public var body: some View {
    let showsUnfilteredSections = query.isEmpty && selectedProvider == nil
    let sections = showsUnfilteredSections ? unfilteredSections : []
    let visibleModels =
      showsUnfilteredSections
      ? sections.flatMap(\.models)
      : filteredModels
    let showsSourceName =
      Set(
        visibleModels.map { $0.displayProvider.displayName }
      ).count > 1

    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Search models", text: $searchText)
          .textFieldStyle(.plain)
          .font(.body)
          .focused($isSearchFocused)
        Button("Clear search", systemImage: "xmark.circle.fill") {
          searchText = ""
          isSearchFocused = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(FritzButtonStyle(.inline))
        .foregroundStyle(.secondary)
        .opacity(searchText.isEmpty ? 0 : 1)
        .disabled(searchText.isEmpty)
        .accessibilityHidden(searchText.isEmpty)
      }
      .padding(12)
      .fixedSize(horizontal: false, vertical: true)

      ModelProviderFlowLayout(spacing: 6) {
        ForEach(ModelPickerData<Value>.providers(from: models, providerOrder: modelProviders)) {
          provider in
          let filterID = provider.id
          let isSelected = selectedProvider == provider
          let isHovered = hoveredProviderFilterID == filterID

          Button {
            selectedProvider = isSelected ? nil : provider
          } label: {
            Text(provider.displayName)
              .font(.callout)
              .foregroundStyle(isSelected ? .primary : .secondary)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(
                isSelected
                  ? style.selectionFill
                  : isHovered
                    ? style.hoverFill
                    : style.quietFill,
                in: Capsule()
              )
              .overlay {
                Capsule()
                  .stroke(
                    isSelected ? style.border : Color.clear
                  )
              }
          }
          .buttonStyle(FritzButtonStyle(.inline))
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityIdentifier("chat-model-provider-filter-\(filterID)")
          .help(
            isSelected
              ? "Show models from all providers"
              : "Show only \(provider.displayName) models"
          )
          .onHover { hovering in
            if hovering {
              hoveredProviderFilterID = filterID
            } else if hoveredProviderFilterID == filterID {
              hoveredProviderFilterID = nil
            }
          }
        }

        Button(action: configureModels) {
          Text("Open Models")
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.tint, in: Capsule())
        }
        .buttonStyle(FritzButtonStyle(.inline))
        .help("Open Model Providers")
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          if showsUnfilteredSections {
            ForEach(sections) { section in
              let sectionShowsSourceName =
                Set(
                  section.models.map { $0.displayProvider.displayName }
                ).count > 1

              // Keep repeated recent/provider models in separate identity scopes.
              VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(.secondary)
                  .padding(.top, 10)
                  .padding(.bottom, 4)
                  .accessibilityAddTraits(.isHeader)

                ForEach(section.models) { model in
                  ChatModelPickerListRow(
                    model: model,
                    selectedModelID: selectedModelID,
                    showsSourceName: sectionShowsSourceName,
                    selectModel: selectModel
                  )
                }
              }
            }
          } else {
            ForEach(visibleModels) { model in
              ChatModelPickerListRow(
                model: model,
                selectedModelID: selectedModelID,
                showsSourceName: showsSourceName,
                selectModel: selectModel
              )
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .padding(.top, 4)
      .overlay {
        if visibleModels.isEmpty {
          Text("No results")
            .font(.body)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: 440, height: 380)
    .background(style.background)
    .onAppear {
      isSearchFocused = true
    }
  }

  private var query: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var unfilteredSections: [ModelPickerSection<Value>] {
    ModelPickerData<Value>.sections(
      from: models,
      recentModels: recentModels,
      providerOrder: modelProviders,
      selectedModelID: selectedModelID
    )
  }

  private var filteredModels: [ModelPickerItem<Value>] {
    let providerModels: [ModelPickerItem<Value>]
    if let selectedProvider {
      providerModels = models.filter { $0.displayProvider == selectedProvider }
    } else {
      providerModels = models
    }

    guard !query.isEmpty else {
      return ModelPickerData<Value>.recommendations(
        from: providerModels,
        providerOrder: selectedProvider.map { [$0.groupID] } ?? modelProviders,
        selectedModelID: selectedModelID,
        limit: recommendationLimit
      )
    }
    return ModelPickerData<Value>.search(providerModels, query: query)
  }
}

private struct ModelProviderFlowLayout: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrangement(width: proposal.width, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let layout = arrangement(width: bounds.width, subviews: subviews)
    for (subview, origin) in zip(subviews, layout.origins) {
      subview.place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        anchor: .topLeading,
        proposal: .unspecified
      )
    }
  }

  private func arrangement(width: CGFloat?, subviews: Subviews) -> (
    size: CGSize, origins: [CGPoint]
  ) {
    let availableWidth = width ?? .infinity
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var contentWidth: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > availableWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      contentWidth = max(contentWidth, x + size.width)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (
      CGSize(width: availableWidth.isFinite ? availableWidth : contentWidth, height: y + rowHeight),
      origins
    )
  }
}

private struct ChatModelPickerListRow<Value>: View {
  @Environment(\.dismiss) private var dismiss
  let model: ModelPickerItem<Value>
  let selectedModelID: String?
  let showsSourceName: Bool
  let selectModel: (ModelPickerItem<Value>) -> Void

  var body: some View {
    Button(action: select) {
      ChatModelPickerRow(
        model: model,
        isSelected: model.id == selectedModelID,
        showsSourceName: showsSourceName
      )
    }
    .buttonStyle(FritzButtonStyle(.inline))
    .accessibilityAddTraits(model.id == selectedModelID ? .isSelected : [])
  }

  private func select() {
    selectModel(model)
    dismiss()
  }
}

private struct ChatModelPickerRow<Value>: View {
  @Environment(\.fritzPickerStyle) private var style
  let model: ModelPickerItem<Value>
  let isSelected: Bool
  let showsSourceName: Bool
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 8) {
      Text(model.displayName)
        .lineLimit(1)
        .truncationMode(.middle)

      Spacer(minLength: 12)

      if let badge = model.badge {
        Image(systemName: badge.systemImage)
          .foregroundStyle(.secondary)
          .help(badge.help)
          .accessibilityLabel(badge.accessibilityLabel)
      }

      if showsSourceName {
        Text(model.displayProvider.displayName)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Image(systemName: "checkmark")
        .font(.body.weight(.semibold))
        .opacity(isSelected ? 1 : 0)
        .accessibilityHidden(true)
    }
    .font(.body)
    .foregroundStyle(.primary)
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isSelected
        ? style.selectionFill
        : isHovered ? style.hoverFill : Color.clear,
      in: RoundedRectangle(cornerRadius: 10)
    )
    .contentShape(Rectangle())
    .onHover { isHovered = $0 }
  }
}
