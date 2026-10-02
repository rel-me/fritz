import Foundation
import Observation

/// Opt-in local-file loading. The host owns this object's lifetime and calls stop on shutdown.
/// Reads are bounded and performed on a separate actor. Polling survives atomic editor saves.
@MainActor @Observable
public final class MarkupFileLoader {
    public private(set) var source: String?
    public private(set) var diagnostic: String?
    public private(set) var fileURL: URL?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let reader = MarkupFileReader()

    public init() {}

    deinit { task?.cancel() }

    /// Select a document, read it once, then watch for stable changes. Errors retain the last source.
    public func open(_ url: URL) async {
        guard !Task.isCancelled else { return }
        stop()
        guard url.isFileURL else {
            diagnostic = "Choose a local markup file."
            return
        }
        fileURL = url
        diagnostic = nil
        let current = generation
        let initial = await reader.read(url)
        guard generation == current else { return }
        guard !Task.isCancelled else {
            diagnostic = "Markup loading was cancelled."
            return
        }
        accept(initial)

        let reader = reader
        task = Task { [weak self] in
            var previous = initial
            var pending: MarkupFileRead?
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                let next = await reader.read(url)
                guard !Task.isCancelled, self?.generation == current else { return }
                // A second identical read debounces writes without relying on timestamps or inodes.
                if next == pending {
                    if next != previous {
                        self?.accept(next)
                        previous = next
                    }
                } else {
                    pending = next
                }
            }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
    }

    private func accept(_ result: MarkupFileRead) {
        switch result {
        case .source(let text):
            source = text
            diagnostic = nil
        case .failure(let message):
            diagnostic = message
        }
    }
}

private enum MarkupFileRead: Sendable, Equatable {
    case source(String)
    case failure(String)
}

private actor MarkupFileReader {
    func read(_ url: URL) -> MarkupFileRead {
        do {
            let resolved = url.resolvingSymlinksInPath()
            let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .failure("Choose a regular markup file.")
            }
            let file = try FileHandle(forReadingFrom: resolved)
            defer { try? file.close() }
            let limit = 256 * 1024
            let data = try file.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else {
                return .failure("Markup files must be at most 256 KiB.")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return .failure("Markup files must use UTF-8 encoding.")
            }
            return .source(text)
        } catch {
            return .failure("Cannot read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
