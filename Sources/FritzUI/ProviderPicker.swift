import SwiftUI

public struct ProviderPicker<Value>: View {
  let selection: ProviderPickerItem<Value>
  let categories: [PickerCategory]
  let onSelect: (ProviderPickerItem<Value>) -> Void
  let providers: [ProviderPickerItem<Value>]
  @State private var isPresented = false

  public init(
    selection: ProviderPickerItem<Value>, providers: [ProviderPickerItem<Value>],
    categories: [PickerCategory], onSelect: @escaping (ProviderPickerItem<Value>) -> Void
  ) {
    self.selection = selection
    self.providers = providers
    self.categories = categories
    self.onSelect = onSelect
  }

  public var body: some View {
    LabeledContent("Provider") {
      Button {
        isPresented = true
      } label: {
        HStack {
          Text(selection.name)
          Image(systemName: "chevron.up.chevron.down")
            .font(.caption)
        }
      }
      .accessibilityLabel("Provider")
      .accessibilityValue(selection.name)
      .popover(isPresented: $isPresented, arrowEdge: .bottom) {
        ProviderPickerContent(selection: selection, categories: categories, providers: providers) {
          provider in
          onSelect(provider)
          isPresented = false
        }
      }
    }
  }
}

public struct ProviderPickerContent<Value>: View {
  @Environment(\.fritzPickerStyle) private var style
  let selection: ProviderPickerItem<Value>
  let categories: [PickerCategory]
  let providers: [ProviderPickerItem<Value>]
  let onSelect: (ProviderPickerItem<Value>) -> Void
  @State private var searchText: String
  @FocusState private var isSearchFocused: Bool
  @State private var hoveredProvider: String?
  @State private var selectedCategory: String
  @State private var hoveredCategory: String?

  public init(
    selection: ProviderPickerItem<Value>,
    initialSearchText: String = "",
    categories: [PickerCategory],
    initialCategoryID: String = "all",
    providers: [ProviderPickerItem<Value>],
    onSelect: @escaping (ProviderPickerItem<Value>) -> Void
  ) {
    self.categories = categories
    self.selection = selection
    self.providers = providers
    self.onSelect = onSelect
    _searchText = State(initialValue: initialSearchText)
    _selectedCategory = State(initialValue: initialCategoryID)
  }

  private var filteredProviders: [ProviderPickerItem<Value>] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return ProviderPickerData.filtered(
      providers, categories: categories, categoryID: selectedCategory, query: query)
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        TextField("Search providers", text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFocused)
          .onSubmit {
            if let provider = filteredProviders.first {
              onSelect(provider)
            }
          }
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

      categoryFilters
      Divider()

      ScrollView {
        VStack(spacing: 2) {
          ForEach(filteredProviders) { provider in
            Button {
              onSelect(provider)
            } label: {
              HStack {
                Text(provider.name)
                if let badge = provider.badgeText {
                  Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                Spacer()
                Image(systemName: "checkmark")
                  .opacity(provider.id == selection.id ? 1 : 0)
                  .accessibilityHidden(true)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 7)
              .background(
                hoveredProvider == provider.id ? Color.primary.opacity(0.08) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(FritzButtonStyle(.inline))
            .onHover { hoveredProvider = $0 ? provider.id : nil }
            .accessibilityAddTraits(provider.id == selection.id ? .isSelected : [])
          }
        }
        .padding(6)
      }
    }
    .frame(width: 440, height: 420, alignment: .top)
    .multilineTextAlignment(.leading)
    .onAppear { isSearchFocused = true }
  }

  private var categoryFilters: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(categories) { category in
          let isSelected = selectedCategory == category.id
          Button {
            selectedCategory = isSelected ? "all" : category.id
          } label: {
            Text(category.title)
              .font(.callout)
              .foregroundStyle(isSelected ? .primary : .secondary)
              .padding(.horizontal, 10)
              .padding(.vertical, 5)
              .background(
                isSelected
                  ? style.selectionFill
                  : hoveredCategory == category.id
                    ? style.hoverFill
                    : style.quietFill,
                in: Capsule()
              )
              .overlay {
                Capsule().stroke(isSelected ? style.border : Color.clear)
              }
          }
          .buttonStyle(FritzButtonStyle(.inline))
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityIdentifier("provider-category-\(category.title.lowercased())")
          .help(category.help)
          .onHover { hoveredCategory = $0 ? category.id : nil }
        }
      }
      .padding(.horizontal, 12)
    }
    .scrollIndicators(.hidden)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.bottom, 10)
  }

}
