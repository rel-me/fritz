import Foundation
import Synchronization
import XCTest
@testable import Fritz

@MainActor
final class RemoteModelCatalogTests: XCTestCase {
    func testProviderCountersNormalizeCacheAndReasoningWithoutInventingPricingTokens() {
        let anthropic = ChatUsageCall(provider: .anthropic, rawUsage: ["input_tokens": 10, "output_tokens": 3, "cache_read_input_tokens": 4, "cache_creation_input_tokens": 2])
        XCTAssertEqual(anthropic.inputTokens, 16)
        XCTAssertEqual(anthropic.totalTokens, 19)
        XCTAssertEqual(anthropic.cachedInputTokens, 4)
        let gemini = ChatUsageCall(provider: .gemini, rawUsage: ["promptTokenCount": 10, "candidatesTokenCount": 3, "thoughtsTokenCount": 2, "totalTokenCount": 15])
        XCTAssertEqual(gemini.outputTokens, 5)
        XCTAssertEqual(gemini.totalTokens, 15)
        let openAI = ChatUsageCall(provider: .openAI, rawUsage: ["input_tokens": 10, "output_tokens": 3, "total_tokens": 13, "input_tokens_details": ["cached_tokens": 4]])
        XCTAssertEqual(openAI.inputTokens, 10)
        XCTAssertEqual(openAI.cachedInputTokens, 4)
        let totalOnly = ChatUsageCall(provider: .openAI, rawUsage: ["total_tokens": 42])
        XCTAssertTrue(totalOnly.reported)
        XCTAssertFalse(totalOnly.hasPricingTokens)
        let catalog = RemoteModelCatalog()
        XCTAssertNil(catalog.summary(usage: ChatUsage(calls: [totalOnly]), provider: .openAI, modelID: "gpt-6-luna", modelName: "Luna").costUSD)
        XCTAssertEqual(catalog.metadata(provider: .openAI, modelID: "gpt-6-luna")?["reasoning"], .bool(true))
    }

    private let payload = Data(#"{"schema_version":1,"model_info":{"currency":"USD","unit":"per_million_tokens","providers":{"openai":{"models":{"fixture":{"cost":{"input":2,"output":10,"cache_read":0.2,"cache_write":2.5,"tiers":[{"input":4,"output":15,"cache_read":0.4,"cache_write":5,"tier":{"type":"context","size":272000}}]}}}}}}}"#.utf8)

    func testRevalidationPersistsPricesAndRetainsThemOnErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); PricingURLProtocol.handler = nil }
        let cacheURL = directory.appendingPathComponent("catalog.json")
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let body = payload
        PricingURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://rel.me/supported-models.json")
            XCTAssertNil(request.value(forHTTPHeaderField: "If-None-Match"))
            return (200, ["ETag": "\"one\""], body)
        }
        let catalog = RemoteModelCatalog(cacheURL: cacheURL, session: session)
        await catalog.refresh()
        XCTAssertNil(catalog.error)
        let short = usage(input: 100_000, output: 10_000, cached: 25_000, writes: 5_000)
        XCTAssertEqual(try XCTUnwrap(summary(catalog, calls: [short]).costUSD), 0.2575, accuracy: 0.000001)

        let restored = RemoteModelCatalog(cacheURL: cacheURL, session: session)
        PricingURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"one\"")
            return (304, [:], Data())
        }
        await restored.refresh()
        XCTAssertNil(restored.error)
        XCTAssertEqual(summary(restored, calls: [short]).costUSD, summary(catalog, calls: [short]).costUSD)
        PricingURLProtocol.handler = { _ in (200, ["ETag": "\"bad\""], Data("{}".utf8)) }
        await restored.refresh()
        XCTAssertNotNil(restored.error)
        XCTAssertEqual(summary(restored, calls: [short]).costUSD, summary(catalog, calls: [short]).costUSD)
        PricingURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"one\"")
            return (500, [:], Data())
        }
        await restored.refresh()
        XCTAssertNotNil(restored.error)

        let partial = usage(input: 10, output: 2, reported: false)
        XCTAssertNil(summary(restored, calls: [short, partial]).costUSD)
        XCTAssertNil(summary(restored, calls: [short], speed: .priority).costUSD)
        let long = usage(input: 300_000, output: 2_000)
        XCTAssertEqual(try XCTUnwrap(summary(restored, calls: [long]).costUSD), 1.23, accuracy: 0.000001)
        let boundary = usage(input: 272_000, output: 0)
        XCTAssertEqual(try XCTUnwrap(summary(restored, calls: [boundary]).costUSD), 0.544, accuracy: 0.000001)
        let shortCalls = [usage(input: 150_000, output: 1_000), usage(input: 150_000, output: 1_000)]
        XCTAssertEqual(try XCTUnwrap(summary(restored, calls: shortCalls).costUSD), 0.62, accuracy: 0.000001)
    }

    func testConcurrentLoadsShareOneRequestAndPublishedCatalogDecodes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); PricingURLProtocol.handler = nil }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let body = try Data(contentsOf: root.appendingPathComponent("Sources/Fritz/ModelCatalog.json"))
        let count = Mutex(0)
        PricingURLProtocol.handler = { _ in
            count.withLock { $0 += 1 }
            return (200, ["ETag": "\"published\""], body)
        }
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let catalog = RemoteModelCatalog(cacheURL: directory.appendingPathComponent("catalog.json"), session: session)
        async let first: Void = catalog.refresh()
        async let second: Void = catalog.refresh()
        _ = await (first, second)
        XCTAssertNil(catalog.error)
        XCTAssertEqual(count.withLock { $0 }, 1)
        let call = usage(input: 100, output: 20)
        let result = catalog.summary(usage: ChatUsage(calls: [call]), provider: .openAI, modelID: "gpt-6-luna", modelName: "Luna")
        XCTAssertEqual(try XCTUnwrap(result.costUSD), 0.00002, accuracy: 0.00000001)
        XCTAssertEqual(result.costSource, "rel.me")
    }

    func testOnlyCompleteProviderCostsOverridePricingAndSummaryRestores() throws {
        let catalog = RemoteModelCatalog(cacheURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let reported = usage(input: 100, output: 20, cost: 0.0123)
        let result = summary(catalog, calls: [reported])
        XCTAssertEqual(result.costSource, "provider")
        XCTAssertEqual(result.costUSD, 0.0123)
        XCTAssertNil(summary(catalog, calls: [reported, usage(input: 100, output: 20)]).costUSD)
        XCTAssertEqual(try JSONDecoder().decode(ChatResponseUsageSummary.self, from: JSONEncoder().encode(result)), result)

    }

    private func summary(_ catalog: RemoteModelCatalog, calls: [ChatUsageCall], speed: ChatSpeed = .standard) -> ChatResponseUsageSummary {
        catalog.summary(usage: ChatUsage(calls: calls), provider: .openAI, modelID: "fixture", modelName: "Fixture", speed: speed)
    }
    private func usage(input: UInt64, output: UInt64, cached: UInt64 = 0, writes: UInt64 = 0, reported: Bool = true, cost: Double? = nil) -> ChatUsageCall {
        ChatUsageCall(reported: reported, inputTokens: input, outputTokens: output, totalTokens: input + output, cachedInputTokens: cached, cacheCreationInputTokens: writes, providerCostUSD: cost)
    }
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PricingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class PricingURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    private static let state = Mutex<Handler?>(nil)
    static var handler: Handler? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.unknown) }
            let (status, headers, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
