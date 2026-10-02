import Foundation

public enum MarkupValueType: String, Sendable, Equatable {
    case string, number, bool
}

public enum MarkupValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)

    public var type: MarkupValueType {
        switch self {
        case .string: .string
        case .number: .number
        case .bool: .bool
        }
    }
}

public struct MarkupSourceLocation: Sendable, Equatable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct MarkupDiagnostic: Error, LocalizedError, Sendable, CustomStringConvertible {
    public let message: String
    public let location: MarkupSourceLocation?

    public init(_ message: String, location: MarkupSourceLocation? = nil) {
        self.message = message
        self.location = location
    }

    public var description: String {
        guard let location else { return message }
        return "Line \(location.line), column \(location.column): \(message)"
    }

    public var errorDescription: String? { description }
}

public enum MarkupPropertyKind: Sendable {
    case value, binding, action
}

public struct MarkupPropertySpec: Sendable {
    public let type: MarkupValueType
    public let kind: MarkupPropertyKind
    public let required: Bool

    public init(type: MarkupValueType, kind: MarkupPropertyKind = .value, required: Bool = false) {
        self.type = type
        self.kind = kind
        self.required = required
    }
}

public struct MarkupElementSpec: Sendable {
    public let properties: [String: MarkupPropertySpec]
    public let allowsChildren: Bool

    public init(properties: [String: MarkupPropertySpec] = [:], allowsChildren: Bool = false) {
        self.properties = properties
        self.allowsChildren = allowsChildren
    }
}

public struct MarkupSchema: Sendable {
    public let components: [String: MarkupElementSpec]
    public let modifiers: [String: MarkupElementSpec]

    public init(components: [String: MarkupElementSpec], modifiers: [String: MarkupElementSpec] = [:]) {
        self.components = components
        self.modifiers = modifiers
    }
}

public enum MarkupPropertyValue: Sendable {
    case literal(MarkupValue)
    case expression(MarkupExpression)
    case binding(String)
    case action(String)

    public func evaluate(variables: [String: MarkupValue]) throws -> MarkupValue {
        switch self {
        case let .literal(value): return value
        case let .expression(expression): return try expression.evaluate(variables: variables)
        case let .binding(name):
            guard let value = variables[name] else {
                throw MarkupDiagnostic("Unknown variable '\(name)'.")
            }
            return value
        case .action:
            throw MarkupDiagnostic("An action cannot be evaluated as a value.")
        }
    }
}

public struct MarkupModifier: Sendable {
    public let name: String
    public let properties: [String: MarkupPropertyValue]
    public let location: MarkupSourceLocation
}

public struct MarkupNode: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let properties: [String: MarkupPropertyValue]
    public let children: [MarkupNode]
    public let modifiers: [MarkupModifier]
    public let location: MarkupSourceLocation
}

public struct MarkupDocument: Sendable {
    public let root: MarkupNode
}
