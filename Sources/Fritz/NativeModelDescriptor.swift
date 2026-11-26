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
    private let abliterated: Bool?
    private let engine: String?
    private let limit: CatalogLimit?

    private struct CatalogLimit: Decodable, Equatable, Sendable {
        let context: UInt32?
        let input: UInt32?
        let automaticTarget: UInt32?

        private enum CodingKeys: String, CodingKey {
            case context, input
            case automaticTarget = "automatic_target"
        }
    }

    public var context: ModelContext? {
        limit.map {
            ModelContext(windowTokens: $0.context, inputTokens: $0.input,
                         automaticWindowTokens: $0.automaticTarget, source: .fritz)
        }
    }

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
                family: String = "Other", category: AIModelCategory = .llm, isAbliterated: Bool = false) {
        self.id = id
        self.name = name
        self.family = family
        self.category = category
        self.size = size
        self.memoryGB = memoryGB
        self.licenseURL = licenseURL
        abliterated = isAbliterated ? true : nil
        benchmarkScore = nil
        engine = nil
        limit = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, family, category, size, abliterated, engine, limit
        case benchmarkScore = "benchmark_score"
        case memoryGB = "memory_gb", licenseURL = "license_url"
    }

    public var isAbliterated: Bool { abliterated == true }
    public var model: DiscoveredAIModel { .init(id: id, displayName: name, context: context) }
    public var downloadSummary: String {
        String(format: "%.2f GB download · %d GB RAM recommended", Double(size) / 1_000_000_000, memoryGB)
    }

    private struct Catalog: Decodable {
        struct Inventory: Decodable { let models: [NativeModelDescriptor] }
        let local_chat: Inventory
        let local_decision: Inventory
    }

    private static let inventories: Catalog = {
        guard let catalog = try? BundledModelCatalog.decode(Catalog.self),
              !catalog.local_chat.models.isEmpty, !catalog.local_decision.models.isEmpty else {
            preconditionFailure("Missing or invalid bundled local model catalog")
        }
        return catalog
    }()

    public static let catalog = inventories.local_chat.models
    public static let decisionCatalog = inventories.local_decision.models
}

