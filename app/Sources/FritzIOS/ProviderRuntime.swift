import Foundation
import os

enum ProviderRuntime {
    struct Model: Decodable, Identifiable, Sendable {
        let id: String
        let displayName: String
    }

    struct Request: Encodable, Sendable {
        let api: String
        let baseURL: String
        let operation: String
        var model: String?
        var messages: [ChatMessage]?

        private enum CodingKeys: String, CodingKey {
            case api, baseURL = "baseUrl", operation, model, messages
        }

        init(_ connection: ProviderConnection, model: String? = nil, messages: [ChatMessage]? = nil) {
            api = connection.kind == .openAI ? "openai" : "compatible"
            baseURL = connection.endpoint
            operation = model == nil ? "discover" : "chat"
            self.model = model
            self.messages = messages
        }
    }

    struct Event: Decodable, Sendable {
        let type: String
        var text: String?
        var models: [Model]?
        var message: String?
    }

    private final class Context: Sendable {
        let continuation: AsyncThrowingStream<Event, any Error>.Continuation
        let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(_ continuation: AsyncThrowingStream<Event, any Error>.Continuation) {
            self.continuation = continuation
        }
    }

    static func events(_ request: Request, key: Data?) -> AsyncThrowingStream<Event, any Error> {
        let (stream, continuation) = AsyncThrowingStream<Event, any Error>.makeStream()
        let context = Context(continuation)
        continuation.onTermination = { [weak context] _ in
            context?.cancelled.withLock { $0 = true }
        }
        // Rust owns networking and blocks this worker until completion or cancellation.
        // Both byte buffers and the callback context live through that synchronous call.
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let input = try JSONEncoder().encode(request)
                let credential = key ?? Data()
                input.withUnsafeBytes { input in
                    credential.withUnsafeBytes { credential in
                        fritz_ios_request(
                            input.bindMemory(to: UInt8.self).baseAddress, input.count,
                            credential.bindMemory(to: UInt8.self).baseAddress, credential.count,
                            Unmanaged.passUnretained(context).toOpaque(),
                            { opaque, bytes, count in
                                guard let opaque, let bytes else { return }
                                let context = Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
                                do {
                                    let event = try JSONDecoder().decode(Event.self, from: Data(bytes: bytes, count: count))
                                    if event.type == "error" {
                                        throw ChatFailure(event.message ?? "The provider request failed.")
                                    }
                                    context.continuation.yield(event)
                                } catch {
                                    context.continuation.finish(throwing: error)
                                }
                            },
                            { opaque in
                                guard let opaque else { return true }
                                return Unmanaged<Context>.fromOpaque(opaque).takeUnretainedValue()
                                    .cancelled.withLock { $0 }
                            }
                        )
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    static func models(for connection: ProviderConnection, key: Data?) async throws -> [Model] {
        for try await event in events(Request(connection), key: key) {
            if let models = event.models { return models }
        }
        try Task.checkCancellation()
        throw ChatFailure("The provider did not return any model information.")
    }
}
