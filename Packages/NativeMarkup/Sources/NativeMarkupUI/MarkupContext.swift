import NativeMarkupCore
import Observation
import SwiftUI

/// The native capabilities made available to a markup document.
/// Keep this context with the host's state owner, independently of document reloads.
/// Registration changes take effect on the next successful `MarkupSession.apply`.
@MainActor @Observable
public final class MarkupContext {
    var bindings: [String: RegisteredBinding] = [:]
    var actions: [String: @MainActor () -> Void] = [:]
    var components: [String: RegisteredComponent] = [:]
    var modifiers: [String: RegisteredModifier] = [:]

    public init() {}

    /// Registers live accessors. Reading the host directly lets SwiftUI observe
    /// its state; persisting a SwiftUI `Binding` here would cache graph values.
    public func registerBinding(
        _ name: String,
        get: @escaping @MainActor () -> String,
        set: @escaping @MainActor (String) -> Void
    ) {
        bindings[name] = .string(get: get, set: set)
    }

    public func registerBinding(
        _ name: String,
        get: @escaping @MainActor () -> Bool,
        set: @escaping @MainActor (Bool) -> Void
    ) {
        bindings[name] = .bool(get: get, set: set)
    }

    public func registerBinding(
        _ name: String,
        get: @escaping @MainActor () -> Double,
        set: @escaping @MainActor (Double) -> Void
    ) {
        bindings[name] = .number(get: get, set: set)
    }

    public func registerAction(_ name: String, _ action: @escaping @MainActor () -> Void) {
        actions[name] = action
    }

    /// Registers a compiled native component and its markup contract.
    /// Built-in component names are reserved and validation rejects overrides.
    public func registerComponent(
        _ name: String,
        specification: MarkupElementSpec,
        render: @escaping @MainActor (MarkupComponentContent) -> AnyView
    ) {
        components[name] = RegisteredComponent(specification: specification, render: render)
    }

    /// Registers a compiled native modifier, preserving its order in `Modifiers`.
    public func registerModifier(
        _ name: String,
        specification: MarkupElementSpec,
        apply: @escaping @MainActor (AnyView, MarkupComponentContent) -> AnyView
    ) {
        modifiers[name] = RegisteredModifier(specification: specification, apply: apply)
    }

}

/// A typed native binding available to a custom component.
@MainActor
public enum MarkupBinding {
    case string(Binding<String>)
    case bool(Binding<Bool>)
    case number(Binding<Double>)
}

@MainActor
enum RegisteredBinding {
    case string(get: @MainActor () -> String, set: @MainActor (String) -> Void)
    case bool(get: @MainActor () -> Bool, set: @MainActor (Bool) -> Void)
    case number(get: @MainActor () -> Double, set: @MainActor (Double) -> Void)

    var type: MarkupValueType {
        switch self {
        case .string: .string
        case .bool: .bool
        case .number: .number
        }
    }

    var value: MarkupValue {
        switch self {
        case let .string(get, _): .string(get())
        case let .bool(get, _): .bool(get())
        case let .number(get, _): .number(get())
        }
    }

    var projection: MarkupBinding {
        switch self {
        case let .string(get, set): .string(Binding(get: { get() }, set: { set($0) }))
        case let .bool(get, set): .bool(Binding(get: { get() }, set: { set($0) }))
        case let .number(get, set): .number(Binding(get: { get() }, set: { set($0) }))
        }
    }
}

/// Validated inputs supplied to a registered native component.
@MainActor
public struct MarkupComponentContent {
    public let values: [String: MarkupValue]
    public let bindings: [String: MarkupBinding]
    public let actions: [String: @MainActor () -> Void]
    public let children: [AnyView]
}

@MainActor
struct RegisteredComponent {
    let specification: MarkupElementSpec
    let render: @MainActor (MarkupComponentContent) -> AnyView
}

@MainActor
struct RegisteredModifier {
    let specification: MarkupElementSpec
    let apply: @MainActor (AnyView, MarkupComponentContent) -> AnyView
}

/// Each installed document retains the capabilities against which it was validated.
@MainActor
struct MarkupCapabilities {
    let bindings: [String: RegisteredBinding]
    let actions: [String: @MainActor () -> Void]
    let components: [String: RegisteredComponent]
    let modifiers: [String: RegisteredModifier]

    init(context: MarkupContext) {
        bindings = context.bindings
        actions = context.actions
        components = context.components
        modifiers = context.modifiers
    }

    var values: [String: MarkupValue] { bindings.mapValues(\.value) }
    var variableTypes: [String: MarkupValueType] { bindings.mapValues(\.type) }
}
