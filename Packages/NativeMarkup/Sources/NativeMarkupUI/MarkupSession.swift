import Foundation
import NativeMarkupCore
import Observation
import SwiftUI

/// Installs valid documents atomically while keeping native state in the host context.
@MainActor @Observable
public final class MarkupSession {
    public let context: MarkupContext
    public private(set) var document: MarkupDocument?
    private var sourceDiagnostic: String?
    private var evaluationDiagnostic: String?
    private var capabilities: MarkupCapabilities?
    var resolvedRoot: ResolvedMarkupNode?

    var values: [String: MarkupValue] { capabilities?.values ?? [:] }

    public var diagnostic: String? {
        [sourceDiagnostic, evaluationDiagnostic].compactMap { $0 }.joined(separator: "\n").nilIfEmpty
    }

    public init(context: MarkupContext) {
        self.context = context
    }

    /// Invalid source leaves the last valid document and all host bindings intact.
    @discardableResult
    public func apply(source: String) -> Bool {
        do {
            let candidateCapabilities = MarkupCapabilities(context: context)
            var components = MarkupVocabulary.components
            for (name, registration) in candidateCapabilities.components {
                guard components[name] == nil else {
                    throw RenderDiagnostic("The component name '\(name)' is reserved.")
                }
                components[name] = registration.specification
            }
            var modifiers = MarkupVocabulary.modifiers
            for (name, registration) in candidateCapabilities.modifiers {
                guard modifiers[name] == nil else {
                    throw RenderDiagnostic("The modifier name '\(name)' is reserved.")
                }
                modifiers[name] = registration.specification
            }
            let parser = MarkupParser(
                schema: MarkupSchema(components: components, modifiers: modifiers),
                variables: candidateCapabilities.variableTypes,
                actions: Set(candidateCapabilities.actions.keys)
            )
            let candidate = try parser.parse(source)
            let root = try resolve(candidate.root, values: candidateCapabilities.values, capabilities: candidateCapabilities)
            document = candidate
            resolvedRoot = root
            capabilities = candidateCapabilities
            sourceDiagnostic = nil
            evaluationDiagnostic = nil
            return true
        } catch {
            sourceDiagnostic = error.localizedDescription
            return false
        }
    }

    /// Re-evaluates expressions against current host values, outside view construction.
    /// A failed evaluation preserves the last rendered values and exposes a diagnostic.
    public func refresh() {
        refresh(values: values)
    }

    func refresh(values: [String: MarkupValue]) {
        guard let document, let capabilities else { return }
        do {
            resolvedRoot = try resolve(document.root, values: values, capabilities: capabilities)
            evaluationDiagnostic = nil
        } catch {
            evaluationDiagnostic = error.localizedDescription
        }
    }

    private func resolve(
        _ node: MarkupNode,
        values: [String: MarkupValue],
        capabilities: MarkupCapabilities
    ) throws -> ResolvedMarkupNode {
        do {
            let properties = try resolveProperties(node.properties, values: values, capabilities: capabilities)
            let children = try node.children.map { try resolve($0, values: values, capabilities: capabilities) }
            let content: ResolvedMarkupContent
            switch node.name {
            case "VStack":
                let alignment = try properties.string("alignment", default: "center")
                try require(alignment, in: ["leading", "center", "trailing"], property: "VStack alignment")
                content = .vStack(alignment, try properties.number("spacing"), children)
            case "HStack":
                let alignment = try properties.string("alignment", default: "center")
                try require(alignment, in: ["top", "center", "bottom", "firstTextBaseline", "lastTextBaseline"], property: "HStack alignment")
                content = .hStack(alignment, try properties.number("spacing"), children)
            case "Text":
                content = .text(try properties.string("value"))
            case "TextField":
                guard case let .string(binding) = properties.bindings["text"] else {
                    throw RenderDiagnostic("TextField requires a String binding for 'text'.")
                }
                content = .textField(try properties.string("title", default: ""), binding)
            case "Toggle":
                guard case let .bool(binding) = properties.bindings["isOn"] else {
                    throw RenderDiagnostic("Toggle requires a Bool binding for 'isOn'.")
                }
                content = .toggle(try properties.string("title"), binding)
            case "Button":
                guard let action = properties.actions["action"] else {
                    throw RenderDiagnostic("Button requires a registered action.")
                }
                content = .button(try properties.string("title"), action)
            case "Divider": content = .divider
            case "Spacer":
                let length = try properties.number("minLength")
                try nonnegative(length, property: "Spacer minLength")
                content = .spacer(length)
            case "ScrollView":
                let axis = try properties.string("axis", default: "vertical")
                try require(axis, in: ["vertical", "horizontal", "both"], property: "ScrollView axis")
                content = .scrollView(axis, children)
            default:
                guard let component = capabilities.components[node.name] else {
                    throw RenderDiagnostic("Unknown component '\(node.name)'.")
                }
                content = .custom(component, properties, children)
            }
            return ResolvedMarkupNode(
                id: node.id,
                content: content,
                modifiers: try node.modifiers.map { try resolveModifier($0, values: values, capabilities: capabilities) }
            )
        } catch let error as RenderDiagnostic {
            throw error.at(node.location)
        } catch let error as MarkupDiagnostic {
            throw MarkupDiagnostic(error.message, location: error.location ?? node.location)
        }
    }

    private func resolveProperties(
        _ properties: [String: MarkupPropertyValue],
        values: [String: MarkupValue],
        capabilities: MarkupCapabilities
    ) throws -> ResolvedProperties {
        var result = ResolvedProperties()
        for (name, property) in properties {
            if case let .action(actionName) = property {
                guard let action = capabilities.actions[actionName] else {
                    throw RenderDiagnostic("Unknown action '\(actionName)'.")
                }
                result.actions[name] = action
            } else {
                let value = try property.evaluate(variables: values)
                if case let .number(number) = value, !number.isFinite {
                    throw RenderDiagnostic("'\(name)' must be a finite number.")
                }
                result.values[name] = value
                if case let .binding(bindingName) = property {
                    guard let binding = capabilities.bindings[bindingName] else {
                        throw RenderDiagnostic("Unknown binding '\(bindingName)'.")
                    }
                    result.bindings[name] = binding.projection
                }
            }
        }
        return result
    }

    private func resolveModifier(
        _ modifier: MarkupModifier,
        values: [String: MarkupValue],
        capabilities: MarkupCapabilities
    ) throws -> ResolvedModifier {
        do {
            let properties = try resolveProperties(modifier.properties, values: values, capabilities: capabilities)
            switch modifier.name {
            case "Padding": return .padding(try properties.requiredNumber("length"))
            case "Frame":
                let width = try properties.number("width")
                let height = try properties.number("height")
                let maxWidth = try properties.number("maxWidth")
                let maxHeight = try properties.number("maxHeight")
                for (key, value) in [("width", width), ("height", height), ("maxWidth", maxWidth), ("maxHeight", maxHeight)] {
                    try nonnegative(value, property: "Frame \(key)")
                }
                return .frame(width: width, height: height, maxWidth: maxWidth, maxHeight: maxHeight)
            case "Background", "ForegroundStyle":
                let name = try properties.string("color")
                guard let color = Self.colors[name] else {
                    throw RenderDiagnostic("Unknown color '\(name)'. Supported colors: \(Self.colors.keys.sorted().joined(separator: ", ")).")
                }
                return modifier.name == "Background" ? .background(color) : .foregroundStyle(color)
            case "Font":
                let name = try properties.string("style")
                guard let font = Self.fonts[name] else {
                    throw RenderDiagnostic("Unknown font style '\(name)'.")
                }
                return .font(font)
            case "Disabled": return .disabled(try properties.bool("value"))
            case "Opacity":
                let value = try properties.requiredNumber("value")
                guard (0 ... 1).contains(value) else {
                    throw RenderDiagnostic("Opacity must be between 0 and 1.")
                }
                return .opacity(value)
            default:
                guard let registration = capabilities.modifiers[modifier.name] else {
                    throw RenderDiagnostic("Unknown modifier '\(modifier.name)'.")
                }
                return .custom(registration, properties)
            }
        } catch let error as RenderDiagnostic {
            throw error.at(modifier.location)
        } catch let error as MarkupDiagnostic {
            throw MarkupDiagnostic(error.message, location: error.location ?? modifier.location)
        }
    }

    private func require(_ value: String, in allowed: [String], property: String) throws {
        guard allowed.contains(value) else {
            throw RenderDiagnostic("Invalid \(property) '\(value)'; expected \(allowed.joined(separator: ", ")).")
        }
    }

    private func nonnegative(_ value: Double?, property: String) throws {
        if let value, value < 0 { throw RenderDiagnostic("\(property) must be nonnegative.") }
    }

    private static let colors: [String: Color] = [
        "primary": .primary, "secondary": .secondary, "accent": .accentColor,
        "clear": .clear, "red": .red, "green": .green, "blue": .blue,
        "orange": .orange, "yellow": .yellow, "purple": .purple, "pink": .pink,
        "gray": .gray, "white": .white, "black": .black,
    ]

    private static let fonts: [String: Font] = [
        "largeTitle": .largeTitle, "title": .title, "title2": .title2, "title3": .title3,
        "headline": .headline, "subheadline": .subheadline, "body": .body,
        "callout": .callout, "footnote": .footnote, "caption": .caption, "caption2": .caption2,
    ]
}

@MainActor
struct ResolvedProperties {
    var values: [String: MarkupValue] = [:]
    var bindings: [String: MarkupBinding] = [:]
    var actions: [String: @MainActor () -> Void] = [:]

    func string(_ name: String, default fallback: String? = nil) throws -> String {
        if case let .string(value) = values[name] { return value }
        if values[name] == nil, let fallback { return fallback }
        throw RenderDiagnostic("'\(name)' requires a String value.")
    }

    func number(_ name: String) throws -> Double? {
        guard let value = values[name] else { return nil }
        guard case let .number(number) = value else { throw RenderDiagnostic("'\(name)' requires a numeric value.") }
        return number
    }

    func requiredNumber(_ name: String) throws -> Double {
        guard let value = try number(name) else { throw RenderDiagnostic("Missing required property '\(name)'.") }
        return value
    }

    func bool(_ name: String) throws -> Bool {
        guard case let .bool(value) = values[name] else { throw RenderDiagnostic("'\(name)' requires a Bool value.") }
        return value
    }
}

private struct RenderDiagnostic: LocalizedError {
    let message: String
    let location: MarkupSourceLocation?

    init(_ message: String, location: MarkupSourceLocation? = nil) {
        self.message = message
        self.location = location
    }

    func at(_ location: MarkupSourceLocation) -> Self {
        self.location == nil ? Self(message, location: location) : self
    }

    var errorDescription: String? {
        guard let location else { return message }
        return "Line \(location.line), column \(location.column): \(message)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
