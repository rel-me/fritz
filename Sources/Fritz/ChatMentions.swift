import Foundation
import Observation

/// A host-owned catalog entry. IDs must remain stable across renames and launches.
/// Entries contain display metadata only; keep credentials and private payloads in the host.
public struct ChatMentionItem: Identifiable, Codable, Hashable, Sendable {
    public struct ID: Codable, Hashable, Sendable {
        public var source: String
        public var value: String
        public init(source: String, value: String) {
            self.source = source
            self.value = value
        }
    }

    public enum Kind: String, Codable, Sendable { case plugin, artifact, entity }
    public var id: ID
    public var name: String
    public var kind: Kind
    public var detail: String

    public init(id: ID, name: String, kind: Kind, detail: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.detail = detail
    }
}

public enum ChatMentionRegistrationError: LocalizedError {
    case invalidSource, invalidItem, duplicateID

    public var errorDescription: String? {
        switch self {
        case .invalidSource: "Reference sources must have a nonempty name on one line."
        case .invalidItem: "References need a nonempty ID in the registered source and a nonempty name on one line."
        case .duplicateID: "Each reference must have a unique ID within its source."
        }
    }
}

/// Own one registry per host/account. Replacing a source supports live catalog refreshes.
@MainActor @Observable
public final class ChatMentionRegistry {
    public private(set) var items: [ChatMentionItem] = []

    public init() {}

    /// Invalid refreshes throw without changing the existing catalog.
    public func register(source: String, items: [ChatMentionItem]) throws {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.contains(where: \.isNewline) else { throw ChatMentionRegistrationError.invalidSource }
        var seen = Set<ChatMentionItem.ID>()
        for item in items {
            guard item.id.source == source,
                  !item.id.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !item.name.contains(where: \.isNewline) else { throw ChatMentionRegistrationError.invalidItem }
            guard seen.insert(item.id).inserted else { throw ChatMentionRegistrationError.duplicateID }
        }
        self.items.removeAll { $0.id.source == source }
        self.items += items
    }

    public func unregister(source: String) {
        items.removeAll { $0.id.source == source }
    }

    public func search(_ query: String) -> [ChatMentionItem] {
        items.filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
                || $0.detail.localizedStandardContains(query)
        }.sorted {
            let left = $0.name.localizedStandardCompare($1.name)
            if left != .orderedSame { return left == .orderedAscending }
            if $0.id.source != $1.id.source { return $0.id.source < $1.id.source }
            return $0.id.value < $1.id.value
        }
    }
}

/// A selected reference uses UTF-16 offsets, matching native macOS text selections.
public struct ChatMentionReference: Codable, Hashable, Sendable {
    public var item: ChatMentionItem
    public var range: NSRange

    public init(item: ChatMentionItem, range: NSRange) {
        self.item = item
        self.range = range
    }
}

/// Persist this value with each draft. Only explicit picker selections create references.
public struct ChatMentionDraft: Codable, Equatable, Sendable {
    public private(set) var text: String
    public private(set) var references: [ChatMentionReference]

    public init(text: String = "") {
        self.text = text
        references = []
    }

    /// Edits inside a mention turn it back into ordinary text; edits before it move its range.
    public mutating func updateText(_ newText: String) {
        guard text != newText else { return }
        let old = Array(text.utf16), new = Array(newText.utf16)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix,
              old[old.count - suffix - 1] == new[new.count - suffix - 1] { suffix += 1 }
        let end = old.count - suffix
        // Repeated identical text can make the edit location ambiguous. Drop any
        // reference in that region rather than attaching the wrong entity to it.
        var fullSuffix = suffix
        while fullSuffix < min(old.count, new.count),
              old[old.count - fullSuffix - 1] == new[new.count - fullSuffix - 1] { fullSuffix += 1 }
        let start = min(prefix, min(old.count, new.count) - fullSuffix)
        let delta = new.count - old.count
        references = references.compactMap { reference in
            var reference = reference
            if NSMaxRange(reference.range) <= start { return reference }
            if reference.range.location >= end {
                reference.range.location += delta
                return reference
            }
            return nil
        }
        text = newText
    }

    public func query(at selection: NSRange) -> (range: NSRange, text: String)? {
        let value = text as NSString
        guard selection.length == 0, selection.location <= value.length,
              let caret = Range(selection, in: text)?.lowerBound else { return nil }
        let prefix = text[..<caret]
        guard let start = prefix.lastIndex(of: "@"),
              start == text.startIndex || text[text.index(before: start)].isWhitespace,
              !references.contains(where: {
                  selection.location > $0.range.location && selection.location <= NSMaxRange($0.range)
              }) else { return nil }
        let query = text[text.index(after: start)..<caret]
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return (NSRange(start..<caret, in: text), String(query))
    }

    /// Returns the caret position after the inserted reference and trailing space.
    @discardableResult
    public mutating func insert(_ item: ChatMentionItem, replacing range: NSRange) -> Int? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        let token = "@" + item.name
        let newText = text.replacingCharacters(in: swiftRange, with: token + " ")
        let delta = token.utf16.count + 1 - range.length
        references = references.compactMap { reference in
            var reference = reference
            if NSMaxRange(reference.range) <= range.location { return reference }
            if reference.range.location >= NSMaxRange(range) {
                reference.range.location += delta
                return reference
            }
            return nil
        }
        text = newText
        references.append(.init(item: item, range: NSRange(location: range.location, length: token.utf16.count)))
        references.sort { $0.range.location < $1.range.location }
        return range.location + token.utf16.count + 1
    }
}
