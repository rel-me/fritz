import XCTest
import Fritz
@testable import FritzUI

final class LocalModelScoreTests: XCTestCase {
    func testUnscoredModelsStayLastInBothSortDirections() {
        struct Row {
            let points: Int?
        }
        let models = [Row(points: nil), Row(points: 10), Row(points: 20)]
        var comparator = LocalModelScoreComparator(points: \Row.points)
        XCTAssertEqual(models.sorted(using: comparator).map(\.points), [20, 10, nil])
        comparator.order = .forward
        XCTAssertEqual(models.sorted(using: comparator).map(\.points), [10, 20, nil])
    }

    func testMinimumScoreAndRunnableFiltersComposeAtTheRecommendedRAM() throws {
        let catalog = NativeModelDescriptor.catalog
        let model = try XCTUnwrap(catalog.first { $0.benchmarkScore != nil })
        let score = try XCTUnwrap(model.benchmarkScore?.points)
        let filter = NativeModelFilters(runnableOnly: true, score: .minimum(score))

        let matchingHardware = LocalModelHardware(memoryGB: model.memoryGB, appleSilicon: true)
        let belowRecommendedRAM = LocalModelHardware(memoryGB: model.memoryGB - 1, appleSilicon: true)
        XCTAssertTrue(filter.models(in: catalog, hardware: matchingHardware).contains(model))
        XCTAssertFalse(filter.models(in: catalog, hardware: belowRecommendedRAM).contains(model))
        XCTAssertTrue(filter.models(in: catalog, hardware: matchingHardware).allSatisfy {
            ($0.benchmarkScore?.points ?? Int.min) >= score
        })
    }

    func testRunnableFilterKeepsCPUDecisionModelsOnMacsWithoutMetal() {
        let catalog = NativeModelDescriptor.catalog + NativeModelDescriptor.decisionCatalog
        let hardware = LocalModelHardware(memoryGB: 64, appleSilicon: false, metalAvailable: false)
        let models = NativeModelFilters(runnableOnly: true).models(in: catalog, hardware: hardware)

        XCTAssertTrue(models.contains { $0.id == "laya-en" })
        XCTAssertFalse(models.contains { $0.id == "bosun-v3.1-0.6b-f16" })
        XCTAssertFalse(models.contains { $0.category == .llm })
    }
}
