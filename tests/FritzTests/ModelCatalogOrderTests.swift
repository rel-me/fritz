import Fritz
import XCTest

final class ModelCatalogOrderTests: XCTestCase {
    func testCatalogDisplayPrioritizesCurrentChatModelsAndKeepsEveryEntry() {
        let ids = ["babbage-002", "gpt-4.1", "gpt-5-nano", "chatgpt-image-latest",
                   "gpt-5-mini", "gpt-5", "gpt-5-pro", "gpt-5.1", "gpt-5.2", "gpt-5.10",
                   "gpt-5-2025-08-07", "o3", "text-embedding-3-large"]
        let models = ids.map { DiscoveredAIModel(id: $0, displayName: $0) }
        let ordered = DiscoveredAIModel.preferredOrder(models, provider: .openAI)
        XCTAssertEqual(ordered.map(\.id), ["gpt-5.10", "gpt-5.2", "gpt-5.1", "gpt-5-pro", "gpt-5", "gpt-5-2025-08-07", "gpt-5-mini", "gpt-5-nano",
                                          "o3", "gpt-4.1", "babbage-002", "chatgpt-image-latest", "text-embedding-3-large"])
    }
}
