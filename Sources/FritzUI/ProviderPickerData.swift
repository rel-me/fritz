import Foundation

public enum ProviderPickerData {
  public static func filtered<Value>(
    _ providers: [ProviderPickerItem<Value>], categories: [PickerCategory],
    categoryID: String = "all", query: String = ""
  ) -> [ProviderPickerItem<Value>] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return providers.filter { provider in
      (categoryID == "all" || provider.categoryIDs.contains(categoryID))
        && (query.isEmpty || provider.name.localizedStandardContains(query)
          || categories.contains {
            $0.id != "all" && provider.categoryIDs.contains($0.id)
              && $0.title.localizedStandardContains(query)
          })
    }.sorted {
      let order = $0.name.localizedStandardCompare($1.name)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }
}
