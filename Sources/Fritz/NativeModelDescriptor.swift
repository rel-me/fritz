import Foundation
import Metal

public struct LocalModelHardware: Sendable {
    public let memoryGB: Int
    public let appleSilicon: Bool
    public let metalAvailable: Bool

    public init(memoryGB: Int, appleSilicon: Bool, metalAvailable: Bool = true) {
        self.memoryGB = memoryGB
        self.appleSilicon = appleSilicon
        self.metalAvailable = metalAvailable
    }

    public static var current: Self {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return Self(
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            appleSilicon: appleSilicon,
            metalAvailable: MTLCreateSystemDefaultDevice() != nil
        )
    }

    public var summary: String {
        "\(appleSilicon ? "Apple silicon" : "Intel Mac") · \(memoryGB) GB memory"
    }

    public func canRun(_ model: NativeModelDescriptor) -> Bool {
        memoryGB >= model.memoryGB && (metalAvailable || !model.requiresMetal)
    }
}

public struct NativeModelDescriptor: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let family: String
    public let category: AIModelCategory
    public let size: UInt64
    public let memoryGB: Int
    public let licenseURL: URL
    public let benchmarkScore: BenchmarkScore?
    private let engine: String?

    public struct BenchmarkScore: Decodable, Equatable, Sendable {
        public let points: Int
        public let configuration: String
        public let sourceURL: URL

        private enum CodingKeys: String, CodingKey {
            case points, configuration
            case sourceURL = "source_url"
        }
    }

    fileprivate var requiresMetal: Bool { category == .llm || engine == "bosun" }

    public init(id: String, name: String, size: UInt64, memoryGB: Int, licenseURL: URL,
                family: String = "Other", category: AIModelCategory = .llm) {
        self.id = id
        self.name = name
        self.family = family
        self.category = category
        self.size = size
        self.memoryGB = memoryGB
        self.licenseURL = licenseURL
        benchmarkScore = nil
        engine = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, family, category, size, engine
        case benchmarkScore = "benchmark_score"
        case memoryGB = "memory_gb", licenseURL = "license_url"
    }

    public var model: DiscoveredAIModel { .init(id: id, displayName: name) }
    public var downloadSummary: String {
        String(format: "%.2f GB download · %d GB RAM recommended", Double(size) / 1_000_000_000, memoryGB)
    }

    public static let catalog = loadCatalog("LocalModels")
    public static let decisionCatalog = loadCatalog("DecisionModels")

    private static func loadCatalog(_ name: String) -> [Self] {
        struct Catalog: Decodable { let models: [NativeModelDescriptor] }
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              !catalog.models.isEmpty else {
            preconditionFailure("Missing or invalid bundled local model catalog")
        }
        return catalog.models
    }
}

