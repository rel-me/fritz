import Foundation
import Observation

/// Public USD-per-million-token prices. Provider discovery remains owned by Fritz.
@MainActor @Observable
public final class RemoteModelCatalog {
    public private(set) var error: String?
    private var cache: Cache?
    private var providers: [String: Provider] = [:]
    private let cacheURL: URL?
    private let session: URLSession
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    public struct Rates: Codable, Equatable, Sendable {
        public let input: Double
        public let output: Double
        public let cache_read: Double?
        public let cache_write: Double?

        public func breakdown(_ usage: ChatUsageCall) -> ChatUsageCostBreakdown? {
            let read = min(usage.inputTokens, usage.cachedInputTokens)
            let write = min(usage.inputTokens - read, usage.cacheCreationInputTokens)
            guard read == 0 || cache_read != nil, write == 0 || cache_write != nil else { return nil }
            let rates = [input, output, cache_read ?? 0, cache_write ?? 0]
            guard rates.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            return ChatUsageCostBreakdown(
                uncachedInputUSD: (Double(usage.inputTokens - read - write) * input + Double(write) * (cache_write ?? 0)) / 1_000_000,
                cachedInputUSD: Double(read) * (cache_read ?? 0) / 1_000_000,
                outputUSD: Double(usage.outputTokens) * output / 1_000_000)
        }
    }
    public struct Cost: Codable, Sendable {
        public let input: Double
        public let output: Double
        public let cache_read: Double?
        public let cache_write: Double?
        public let tiers: [Tier]?
        public let context_over_200k: Rates?
        public struct Tier: Codable, Sendable {
            public let input: Double
            public let output: Double
            public let cache_read: Double?
            public let cache_write: Double?
            public let tier: Threshold
            public struct Threshold: Codable, Sendable { public let type: String; public let size: UInt64? }
        }
        public func breakdown(_ usage: ChatUsageCall) -> ChatUsageCostBreakdown? {
            var rates = Rates(input: input, output: output, cache_read: cache_read, cache_write: cache_write)
            if let tiers, !tiers.isEmpty {
                guard tiers.allSatisfy({ $0.tier.type == "context" && $0.tier.size != nil }) else { return nil }
                for tier in tiers.sorted(by: { $0.tier.size! < $1.tier.size! }) where usage.inputTokens > tier.tier.size! {
                    rates = Rates(input: tier.input, output: tier.output, cache_read: tier.cache_read, cache_write: tier.cache_write)
                }
            } else if let context_over_200k, usage.inputTokens > 200_000 {
                rates = context_over_200k
            }
            return rates.breakdown(usage)
        }
    }
    struct Model: Decodable, Sendable {
        let cost: Cost?
        let information: [String: ModelCatalogValue]
        init(from decoder: any Decoder) throws {
            information = try decoder.singleValueContainer().decode([String: ModelCatalogValue].self)
            if let value = information["cost"], value != .null {
                cost = try JSONDecoder().decode(Cost.self, from: JSONEncoder().encode(value))
            } else { cost = nil }
        }
    }
    struct Provider: Decodable, Sendable { let models: [String: Model] }
    private struct Catalog: Decodable {
        let schema_version: Int
        let model_info: ModelInfo
        struct ModelInfo: Decodable { let currency: String; let unit: String; let providers: [String: Provider] }
    }
    private struct Cache: Codable { let catalog: Data; let etag: String?; let lastModified: String? }

    public init(cacheURL: URL? = nil, session: URLSession = .shared) {
        self.cacheURL = cacheURL
        self.session = session
        do {
            guard let url = Bundle.module.url(forResource: "ModelCatalog", withExtension: "json") else { throw URLError(.fileDoesNotExist) }
            providers = try Self.decode(Data(contentsOf: url))
        } catch { self.error = "Could not read bundled model catalog: \(error.localizedDescription)" }
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let saved = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheURL))
                providers = try Self.decode(saved.catalog)
                cache = saved
            }
            catch { self.error = "Could not read pricing catalog: \(error.localizedDescription)" }
        }
    }

    /// Revalidate on every Models load; concurrent consumers share the same request.
    public func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { await revalidate() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func revalidate() async {
        do {
            var request = URLRequest(url: URL(string: "https://rel.me/supported-models.json")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            if let etag = cache?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            else if let modified = cache?.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 304, cache != nil { error = nil; return }
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
            let providers = try Self.decode(data)
            let next = Cache(catalog: data, etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
            if let cacheURL {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(next).write(to: cacheURL, options: .atomic)
            }
            cache = next
            self.providers = providers
            error = nil
        } catch { self.error = "Could not refresh pricing catalog: \(error.localizedDescription)" }
    }

    public func summary(usage: ChatUsage, provider: AIProviderKind, modelID: String, modelName: String, speed: ChatSpeed = .standard) -> ChatResponseUsageSummary {
        let calls = usage.calls.filter { !$0.localDecision }
        var cost: Double?
        var source: String?
        if !calls.isEmpty, calls.allSatisfy({ $0.providerCostUSD.map { $0.isFinite && $0 >= 0 } == true }) {
            cost = calls.reduce(0) { $0 + $1.providerCostUSD! }; source = "provider"
        } else if provider == .fritz || provider == .ollama {
            cost = 0; source = "local"
        } else if speed == .standard, !calls.isEmpty, calls.allSatisfy(\.hasPricingTokens),
                  let pricing = pricing(provider: provider, modelID: modelID) {
            let costs = calls.compactMap { pricing.breakdown($0)?.totalUSD }
            if costs.count == calls.count { cost = costs.reduce(0, +); source = "rel.me" }
        }
        return ChatResponseUsageSummary(usage: usage, modelName: modelName, costUSD: cost, costSource: source)
    }

    private static func decode(_ data: Data) throws -> [String: Provider] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        guard catalog.schema_version == 1, catalog.model_info.currency == "USD", catalog.model_info.unit == "per_million_tokens",
              !catalog.model_info.providers.isEmpty,
              catalog.model_info.providers.values.contains(where: { !$0.models.isEmpty }) else { throw URLError(.cannotParseResponse) }
        return catalog.model_info.providers
    }

    public func pricing(provider kind: AIProviderKind, modelID: String) -> Cost? {
        model(provider: kind, modelID: modelID)?.cost
    }

    /// Information enriches discovered models; its presence never establishes API availability.
    public func metadata(provider: AIProviderKind, modelID: String) -> [String: ModelCatalogValue]? {
        model(provider: provider, modelID: modelID)?.information
    }

    private func model(provider kind: AIProviderKind, modelID: String) -> Model? {
        let provider: String
        switch kind {
        case .openAI: provider = "openai"
        case .anthropic: provider = "anthropic"
        case .gemini: provider = "gemini"
        case .openRouter: provider = "openrouter"
        default: return nil // Custom endpoints must not inherit another provider's prices.
        }
        return providers[provider]?.models[modelID]
    }
}
