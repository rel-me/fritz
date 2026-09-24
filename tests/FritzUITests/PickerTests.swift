import FritzUI
import SwiftUI
import XCTest

final class PickerTests: XCTestCase {
  private func model(
    _ id: String, group: String = "rel", display: String? = nil, recommended: Bool = true
  ) -> ModelPickerItem<String> {
    .init(
      id: id, value: "host:\(id)", displayName: id, modelID: id,
      provider: .init(id: display ?? group, displayName: display ?? group, groupID: group),
      sourceName: "Work account", isRecommended: recommended)
  }

  func testSectionsKeepRecentIdentityScopedAndSeparateHostedAdapters() {
    let models = [
      model("local"), model("generic", group: "compatible"),
      model("aws", group: "compatible", display: "bedrock"),
    ]
    let sections = ModelPickerData.sections(
      from: models, recentModels: [models[0], model("deleted")],
      providerOrder: ["compatible", "rel"])
    XCTAssertEqual(sections.map(\.title), ["Recent", "compatible", "bedrock", "rel"])
    XCTAssertEqual(sections.first?.models.map(\.id), ["local"])
    XCTAssertEqual(sections.last?.models.first?.value, "host:local")
    XCTAssertNotEqual(sections.first?.id, sections.last?.id)
  }

  func testSectionsExcludeSelectedModelFromRecents() {
    let models = [model("selected"), model("other")]
    let sections = ModelPickerData.sections(
      from: models, recentModels: models, providerOrder: ["rel"],
      selectedModelID: "selected")

    XCTAssertEqual(sections.first?.id, .recent)
    XCTAssertEqual(sections.first?.models.map(\.id), ["other"])
  }

  func testRecommendationsPreserveSelectionAndBalanceHostGroups() {
    let models = [
      model("local"), model("jev", group: "jev"), model("cloud", group: "openai"),
      model("embedding", recommended: false),
    ]
    let selected = ModelPickerData.recommendations(
      from: models, providerOrder: ["rel", "jev", "openai"], selectedModelID: "embedding", limit: 3)
    XCTAssertEqual(selected.map(\.id), ["embedding", "jev", "cloud"])
    XCTAssertTrue(
      ModelPickerData.recommendations(
        from: models, providerOrder: [], selectedModelID: nil, limit: 0
      ).isEmpty)
    XCTAssertEqual(ModelPickerData.search(models, query: " work ACCOUNT ").count, 4)
  }

  func testProviderSearchCategoriesAndOriginalValues() {
    let local = ProviderPickerItem(
      id: "rel", value: 42, name: "REL", categoryIDs: ["local"], badgeText: "local")
    let remote = ProviderPickerItem(
      id: "jev", value: 73, name: "TypeSafe AI", categoryIDs: ["remote"])
    let categories: [PickerCategory] = [
      .all, .init(id: "local", title: "Local", help: "REL and Ollama"),
    ]
    XCTAssertEqual(
      ProviderPickerData.filtered([remote, local], categories: categories, query: "LOCAL").map(
        \.value), [42])
    XCTAssertTrue(
      ProviderPickerData.filtered(
        [remote, local], categories: categories, categoryID: "remote", query: "REL"
      ).isEmpty)
  }

  @MainActor func testPublicViewsAcceptHostValuesAndBrandingWithoutFritzModels() {
    let item = model("local")
    _ = ModelPickerPopover(
      models: [item], recentModels: [], modelProviders: ["rel"], selectedModelID: item.id,
      selectModel: { _ in }, configureModels: {})
    let provider = ProviderPickerItem(id: "rel", value: 1, name: "REL")
    _ = ProviderPicker(
      selection: provider, providers: [provider], categories: [.all], onSelect: { _ in })
    _ = ProviderPickerContent(
      selection: provider, categories: [.all], providers: [provider], onSelect: { _ in })
    _ = FritzButtonStyle(.toolbar)
    _ = FritzGlassControlGroup()
    _ = FritzPanelIconControl(isEmphasized: true)
  }
}
