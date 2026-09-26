import FritzUI
import Fritz
import SwiftUI

struct AIProviderPicker: View {
    @Binding var selection: AIProviderPreset
    var providers: [AIProviderPreset] = AIProviderPreset.allCases

    var body: some View {
        FritzUI.ProviderPicker(
            selection: AIProviderPickerContent.item(selection),
            providers: providers.map(AIProviderPickerContent.item),
            categories: AIProviderPickerContent.categories(for: providers),
            onSelect: { selection = $0.value }
        )
    }
}

struct AIProviderPickerContent: View {
    let selection: AIProviderPreset
    var initialSearchText = ""
    var initialCategory: AIProviderCategory = .all
    var providers: [AIProviderPreset] = AIProviderPreset.allCases
    let onSelect: (AIProviderPreset) -> Void

    var body: some View {
        FritzUI.ProviderPickerContent(
            selection: Self.item(selection), initialSearchText: initialSearchText,
            categories: Self.categories(for: providers), initialCategoryID: initialCategory.rawValue.lowercased(),
            providers: providers.map(Self.item), onSelect: { onSelect($0.value) }
        )
    }

    static var categories: [PickerCategory] {
        AIProviderCategory.allCases.map {
            .init(id: $0.rawValue.lowercased(), title: $0.rawValue, help: $0.help)
        }
    }

    static func categories(for providers: [AIProviderPreset]) -> [PickerCategory] {
        AIProviderCategory.allCases
            .filter { category in category == .all || providers.contains(where: category.contains) }
            .map { .init(id: $0.rawValue.lowercased(), title: $0.rawValue, help: $0.help) }
    }

    static func item(_ provider: AIProviderPreset) -> ProviderPickerItem<AIProviderPreset> {
        .init(id: provider.id, value: provider, name: provider.name,
              categoryIDs: Set(AIProviderCategory.allCases.filter { $0.contains(provider) }.map { $0.rawValue.lowercased() }),
              badgeText: AIProviderCategory.local.contains(provider) ? "local" : nil)
    }
}
