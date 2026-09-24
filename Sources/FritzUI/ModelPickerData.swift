import Foundation

public struct ModelPickerSection<Value>: Identifiable {
  public enum ID: Hashable {
    case recent
    case provider(String)
  }
  public let id: ID
  public let title: String
  public let models: [ModelPickerItem<Value>]
}

public enum ModelPickerData<Value> {
  public static func providers(from models: [ModelPickerItem<Value>], providerOrder: [String])
    -> [PickerProvider]
  {
    var seen = Set<String>()
    return (providerOrder + models.map { $0.displayProvider.groupID }).flatMap { group in
      models.filter { $0.displayProvider.groupID == group }.map(\.displayProvider)
    }.filter { seen.insert($0.id).inserted }
  }

  public static func sections(
    from models: [ModelPickerItem<Value>], recentModels: [ModelPickerItem<Value>],
    providerOrder: [String], selectedModelID: String? = nil,
    recentLimit: Int = 5, providerLimit: Int = 5
  ) -> [ModelPickerSection<Value>] {
    var sections: [ModelPickerSection<Value>] = []
    let available = Set(models.map(\.id))
    let recent = Array(
      recentModels.filter {
        available.contains($0.id) && $0.id != selectedModelID
      }.prefix(max(0, recentLimit)))
    if !recent.isEmpty { sections.append(.init(id: .recent, title: "Recent", models: recent)) }
    for provider in providers(from: models, providerOrder: providerOrder) {
      let visible = Array(
        models.filter { $0.displayProvider.id == provider.id && $0.isRecommended }.prefix(
          max(0, providerLimit)))
      if !visible.isEmpty {
        sections.append(
          .init(id: .provider(provider.id), title: provider.displayName, models: visible))
      }
    }
    return sections
  }

  public static func search(_ models: [ModelPickerItem<Value>], query: String) -> [ModelPickerItem<
    Value
  >] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return models }
    return models.filter {
      $0.displayName.localizedStandardContains(query) || $0.modelID.localizedStandardContains(query)
        || $0.displayProvider.displayName.localizedStandardContains(query)
        || $0.sourceName?.localizedStandardContains(query) == true
    }
  }
  public static func recommendations(
    from options: [ModelPickerItem<Value>],
    providerOrder: [String],
    selectedModelID: String?,
    limit: Int
  ) -> [ModelPickerItem<Value>] {
    guard limit > 0 else { return [] }

    let selectedModel = selectedModelID.flatMap { selectedModelID in
      options.first { $0.id == selectedModelID }
    }
    var recommendations = selectedModel.map { [$0] } ?? []
    guard recommendations.count < limit else { return recommendations }

    let availableProviders = Set(options.map { $0.displayProvider.groupID })
    var seenProviders: Set<String> = []
    let orderedProviders = (providerOrder + options.map { $0.displayProvider.groupID }).filter {
      provider in
      availableProviders.contains(provider) && seenProviders.insert(provider).inserted
    }
    let recommendedByProvider = Dictionary(
      grouping: options.filter { option in
        option.id != selectedModelID
          && option.isRecommended
      },
      by: { $0.displayProvider.groupID }
    )
    var nextIndexByProvider: [String: Int] = [:]

    func appendNextRecommendation(for provider: String) -> Bool {
      let nextIndex = nextIndexByProvider[provider, default: 0]
      guard let providerModels = recommendedByProvider[provider],
        nextIndex < providerModels.count
      else {
        return false
      }
      recommendations.append(providerModels[nextIndex])
      nextIndexByProvider[provider] = nextIndex + 1
      return true
    }

    for provider in orderedProviders where provider != selectedModel?.displayProvider.groupID {
      guard recommendations.count < limit else { return recommendations }
      _ = appendNextRecommendation(for: provider)
    }

    while recommendations.count < limit {
      var appendedRecommendation = false
      for provider in orderedProviders {
        guard recommendations.count < limit else { return recommendations }
        appendedRecommendation =
          appendNextRecommendation(for: provider)
          || appendedRecommendation
      }
      guard appendedRecommendation else { break }
    }
    return recommendations
  }
}
