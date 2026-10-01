import Foundation

/// A bounded expression language. This parses values and pure operations, not Swift source.
public struct MarkupExpression: Sendable {
    private let root: ExpressionNode

    // A $reference names an exact host key; it must not reinterpret that key as
    // expression source (for example, the key "123" is not the number 123).
    static func reference(_ name: String) -> MarkupExpression {
        MarkupExpression(root: .variable(name))
    }

    public static func parse(_ source: String) throws -> MarkupExpression {
        guard source.utf8.count <= 4_096 else {
            throw MarkupDiagnostic("Expression exceeds the 4096-byte limit.")
        }
        var lexer = ExpressionLexer(source: source)
        var parser = ExpressionParser(tokens: try lexer.tokenize())
        let root = try parser.parse()
        guard root.depth <= 64 else {
            throw MarkupDiagnostic("Expression exceeds the depth limit of 64.")
        }
        return MarkupExpression(root: root)
    }

    public func typecheck(variables: [String: MarkupValueType]) throws -> MarkupValueType {
        try root.typecheck(variables: variables)
    }

    public func evaluate(variables: [String: MarkupValue]) throws -> MarkupValue {
        _ = try root.typecheck(variables: variables.mapValues(\.type))
        return try root.evaluate(variables: variables)
    }
}

private indirect enum ExpressionNode: Sendable {
    case literal(MarkupValue)
    case variable(String)
    case unary(String, ExpressionNode)
    case binary(String, ExpressionNode, ExpressionNode)
    case function(String, ExpressionNode)

    var depth: Int {
        switch self {
        case .literal, .variable: 1
        case let .unary(_, child), let .function(_, child): child.depth + 1
        case let .binary(_, lhs, rhs): max(lhs.depth, rhs.depth) + 1
        }
    }

    func typecheck(variables: [String: MarkupValueType]) throws -> MarkupValueType {
        switch self {
        case let .literal(value): return value.type
        case let .variable(name):
            guard let type = variables[name] else { throw unknownVariable(name) }
            return type
        case let .unary(op, child):
            let expected: MarkupValueType = op == "!" ? .bool : .number
            try require(try child.typecheck(variables: variables), expected, operation: op)
            return expected
        case let .function(name, argument):
            try require(try argument.typecheck(variables: variables), .string, operation: name)
            return name == "isEmpty" ? .bool : .number
        case let .binary(op, lhs, rhs):
            let left = try lhs.typecheck(variables: variables)
            let right = try rhs.typecheck(variables: variables)
            guard left == right else {
                throw MarkupDiagnostic("Operator '\(op)' requires matching operand types, received \(left.rawValue) and \(right.rawValue).")
            }
            switch op {
            case "&&", "||":
                try require(left, .bool, operation: op)
                return .bool
            case "==", "!=": return .bool
            case "<", "<=", ">", ">=":
                try require(left, .number, operation: op)
                return .bool
            case "+" where left == .string: return .string
            default:
                try require(left, .number, operation: op)
                return .number
            }
        }
    }

    func evaluate(variables: [String: MarkupValue]) throws -> MarkupValue {
        switch self {
        case let .literal(value): return value
        case let .variable(name):
            guard let value = variables[name] else { throw unknownVariable(name) }
            if case let .number(number) = value, !number.isFinite {
                throw MarkupDiagnostic("Variable '\(name)' must be a finite number.")
            }
            return value
        case let .unary(op, child):
            let value = try child.evaluate(variables: variables)
            switch (op, value) {
            case let ("!", .bool(value)): return .bool(!value)
            case let ("-", .number(value)): return .number(-value)
            default: throw MarkupDiagnostic("Invalid operand for '\(op)'.")
            }
        case let .function(name, argument):
            guard case let .string(value) = try argument.evaluate(variables: variables) else {
                throw MarkupDiagnostic("Function '\(name)' requires a string.")
            }
            return name == "isEmpty" ? .bool(value.isEmpty) : .number(Double(value.count))
        case let .binary(op, lhs, rhs):
            let left = try lhs.evaluate(variables: variables)
            // Keep the right side unevaluated for boolean short-circuiting.
            if op == "&&", left == .bool(false) { return .bool(false) }
            if op == "||", left == .bool(true) { return .bool(true) }
            let right = try rhs.evaluate(variables: variables)
            guard left.type == right.type else {
                throw MarkupDiagnostic("Operator '\(op)' requires matching operand types.")
            }
            if op == "==" { return .bool(left == right) }
            if op == "!=" { return .bool(left != right) }
            if case let .bool(a) = left, case let .bool(b) = right {
                if op == "&&" { return .bool(a && b) }
                if op == "||" { return .bool(a || b) }
            }
            if op == "+", case let .string(a) = left, case let .string(b) = right {
                guard a.utf8.count + b.utf8.count <= 262_144 else {
                    throw MarkupDiagnostic("Expression string result exceeds 256 KiB.")
                }
                return .string(a + b)
            }
            guard case let .number(a) = left, case let .number(b) = right else {
                throw MarkupDiagnostic("Invalid operands for '\(op)'.")
            }
            switch op {
            case "<": return .bool(a < b)
            case "<=": return .bool(a <= b)
            case ">": return .bool(a > b)
            case ">=": return .bool(a >= b)
            default: break
            }
            let result: Double
            switch op {
            case "+": result = a + b
            case "-": result = a - b
            case "*": result = a * b
            case "/", "%":
                guard b != 0 else { throw MarkupDiagnostic("Division by zero.") }
                result = op == "/" ? a / b : a.truncatingRemainder(dividingBy: b)
            default: throw MarkupDiagnostic("Invalid operator '\(op)'.")
            }
            guard result.isFinite else { throw MarkupDiagnostic("Arithmetic result must be finite.") }
            return .number(result)
        }
    }

    private func unknownVariable(_ name: String) -> MarkupDiagnostic {
        MarkupDiagnostic("Unknown variable '\(name)'.")
    }

    private func require(_ actual: MarkupValueType, _ expected: MarkupValueType, operation: String) throws {
        guard actual == expected else {
            throw MarkupDiagnostic("'\(operation)' requires \(expected.rawValue), received \(actual.rawValue).")
        }
    }
}

private enum ExpressionToken: Equatable {
    case value(MarkupValue), identifier(String), symbol(String), end
}

private struct ExpressionLexer {
    let characters: [Character]
    var index = 0

    init(source: String) { characters = Array(source) }

    mutating func tokenize() throws -> [ExpressionToken] {
        var tokens: [ExpressionToken] = []
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace { index += 1; continue }
            guard tokens.count < 512 else { throw MarkupDiagnostic("Expression exceeds the 512-token limit.") }
            if character == "\"" || character == "'" {
                tokens.append(.value(.string(try string())))
            } else if character.isASCII && character.isNumber {
                tokens.append(.value(.number(try number())))
            } else if Self.isIdentifierStart(character) {
                let start = index
                index += 1
                while index < characters.count && Self.isIdentifierContinuation(characters[index]) { index += 1 }
                let name = String(characters[start..<index])
                guard Self.isVariableName(name) else { throw MarkupDiagnostic("Invalid variable name '\(name)'.") }
                switch name {
                case "true": tokens.append(.value(.bool(true)))
                case "false": tokens.append(.value(.bool(false)))
                default: tokens.append(.identifier(name))
                }
            } else {
                let pair = index + 1 < characters.count ? String(characters[index...index + 1]) : ""
                if ["&&", "||", "==", "!=", "<=", ">="].contains(pair) {
                    index += 2
                    tokens.append(.symbol(pair))
                } else if "()+-*/%!<>,".contains(character) {
                    index += 1
                    tokens.append(.symbol(String(character)))
                } else {
                    throw MarkupDiagnostic("Unexpected character '\(character)' in expression.")
                }
            }
        }
        tokens.append(.end)
        return tokens
    }

    static func isVariableName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            guard let first = part.first, isIdentifierStart(first) else { return false }
            return part.dropFirst().allSatisfy { isIdentifierStart($0) || ($0.isASCII && $0.isNumber) }
        }
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && character.isLetter)
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character) || character == "." || (character.isASCII && character.isNumber)
    }

    private mutating func number() throws -> Double {
        let start = index
        while index < characters.count && characters[index].isASCII && characters[index].isNumber { index += 1 }
        if index < characters.count && characters[index] == "." {
            index += 1
            while index < characters.count && characters[index].isASCII && characters[index].isNumber { index += 1 }
        }
        if index < characters.count && (characters[index] == "e" || characters[index] == "E") {
            index += 1
            if index < characters.count && (characters[index] == "+" || characters[index] == "-") { index += 1 }
            while index < characters.count && characters[index].isASCII && characters[index].isNumber { index += 1 }
        }
        guard let value = Double(String(characters[start..<index])), value.isFinite else {
            throw MarkupDiagnostic("Invalid or non-finite number in expression.")
        }
        return value
    }

    private mutating func string() throws -> String {
        let quote = characters[index]
        index += 1
        var result = ""
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == quote { return result }
            if character == "\\" {
                guard index < characters.count else { break }
                let escaped = characters[index]
                index += 1
                switch escaped {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "\\", "\"", "'": result.append(escaped)
                default: throw MarkupDiagnostic("Unsupported string escape '\\\(escaped)'.")
                }
            } else {
                result.append(character)
            }
        }
        throw MarkupDiagnostic("Unterminated string literal.")
    }
}

private struct ExpressionParser {
    let tokens: [ExpressionToken]
    var index = 0
    var nesting = 0

    mutating func parse() throws -> ExpressionNode {
        let root = try expression(minimumPrecedence: 0)
        guard tokens[index] == .end else { throw MarkupDiagnostic("Unexpected trailing expression input.") }
        return root
    }

    private mutating func expression(minimumPrecedence: Int) throws -> ExpressionNode {
        nesting += 1
        defer { nesting -= 1 }
        guard nesting <= 64 else { throw MarkupDiagnostic("Expression exceeds the depth limit of 64.") }
        var lhs = try primary()
        while case let .symbol(op) = tokens[index], let precedence = Self.precedence[op], precedence >= minimumPrecedence {
            index += 1
            let rhs = try expression(minimumPrecedence: precedence + 1)
            lhs = .binary(op, lhs, rhs)
        }
        return lhs
    }

    private mutating func primary() throws -> ExpressionNode {
        let token = tokens[index]
        switch token {
        case let .value(value):
            index += 1
            return .literal(value)
        case let .identifier(name):
            index += 1
            if tokens[index] == .symbol("(") {
                guard name == "isEmpty" || name == "count" else {
                    throw MarkupDiagnostic("Unknown function '\(name)'. Supported functions: isEmpty, count.")
                }
                index += 1
                let argument = try expression(minimumPrecedence: 0)
                try consume(")")
                return .function(name, argument)
            }
            return .variable(name)
        case .symbol("("):
            index += 1
            let value = try expression(minimumPrecedence: 0)
            try consume(")")
            return value
        case let .symbol(op) where op == "!" || op == "-":
            index += 1
            return .unary(op, try expression(minimumPrecedence: 7))
        default:
            throw MarkupDiagnostic("Expected a value, variable, function, or parenthesized expression.")
        }
    }

    private mutating func consume(_ symbol: String) throws {
        guard tokens[index] == .symbol(symbol) else {
            throw MarkupDiagnostic("Expected '\(symbol)' in expression.")
        }
        index += 1
    }

    private static let precedence = ["||": 1, "&&": 2, "==": 3, "!=": 3, "<": 4, "<=": 4, ">": 4, ">=": 4, "+": 5, "-": 5, "*": 6, "/": 6, "%": 6]
}
