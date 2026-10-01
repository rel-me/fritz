import NativeMarkupCore
import SwiftUI

/// Renders a session's last valid document using native SwiftUI controls.
/// Show `session.diagnostic` beside this view to expose source and evaluation errors.
@MainActor
public struct MarkupView: View {
    private let session: MarkupSession

    public init(session: MarkupSession) {
        self.session = session
    }

    public var body: some View {
        let snapshot = ObservedMarkupValues(values: session.values)
        Group {
            if let root = session.resolvedRoot {
                MarkupNodeView(node: root)
                    .id(root.id)
            }
        }
        .onChange(of: snapshot, initial: true) { _, snapshot in
            session.refresh(values: snapshot.values)
        }
    }
}

/// Observation needs stable equality even for unused host values containing NaN.
/// The original values still reach evaluation, which rejects nonfinite numbers.
private struct ObservedMarkupValues: Equatable {
    let values: [String: MarkupValue]

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.values.count == rhs.values.count else { return false }
        return lhs.values.allSatisfy { key, value in
            guard let other = rhs.values[key] else { return false }
            if case let .number(left) = value, case let .number(right) = other,
               left.isNaN, right.isNaN {
                return true
            }
            return value == other
        }
    }
}

@MainActor
struct ResolvedMarkupNode: Identifiable {
    let id: String
    let content: ResolvedMarkupContent
    let modifiers: [ResolvedModifier]
}

@MainActor
indirect enum ResolvedMarkupContent {
    case vStack(String, Double?, [ResolvedMarkupNode])
    case hStack(String, Double?, [ResolvedMarkupNode])
    case text(String)
    case textField(String, Binding<String>)
    case toggle(String, Binding<Bool>)
    case button(String, @MainActor () -> Void)
    case divider
    case spacer(Double?)
    case scrollView(String, [ResolvedMarkupNode])
    case custom(RegisteredComponent, ResolvedProperties, [ResolvedMarkupNode])
}

@MainActor
enum ResolvedModifier {
    case padding(Double)
    case frame(width: Double?, height: Double?, maxWidth: Double?, maxHeight: Double?)
    case background(Color)
    case foregroundStyle(Color)
    case font(Font)
    case disabled(Bool)
    case opacity(Double)
    case custom(RegisteredModifier, ResolvedProperties)

    func apply(to view: AnyView) -> AnyView {
        switch self {
        case let .padding(length): AnyView(view.padding(length))
        case let .frame(width, height, maxWidth, maxHeight):
            AnyView(view.frame(width: width.map { CGFloat($0) }, height: height.map { CGFloat($0) })
                .frame(maxWidth: maxWidth.map { CGFloat($0) }, maxHeight: maxHeight.map { CGFloat($0) }))
        case let .background(color): AnyView(view.background(color))
        case let .foregroundStyle(color): AnyView(view.foregroundStyle(color))
        case let .font(font): AnyView(view.font(font))
        case let .disabled(value): AnyView(view.disabled(value))
        case let .opacity(value): AnyView(view.opacity(value))
        case let .custom(registration, properties):
            registration.apply(view, MarkupComponentContent(
                values: properties.values,
                bindings: properties.bindings,
                actions: properties.actions,
                children: []
            ))
        }
    }
}

@MainActor
private struct MarkupNodeView: View {
    let node: ResolvedMarkupNode

    var body: some View {
        node.modifiers.reduce(AnyView(content)) { view, modifier in
            modifier.apply(to: view)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node.content {
        case let .vStack(alignment, spacing, children):
            VStack(alignment: horizontalAlignment(alignment), spacing: spacing.map { CGFloat($0) }) {
                ForEach(children) { MarkupNodeView(node: $0) }
            }
        case let .hStack(alignment, spacing, children):
            HStack(alignment: verticalAlignment(alignment), spacing: spacing.map { CGFloat($0) }) {
                ForEach(children) { MarkupNodeView(node: $0) }
            }
        case let .text(value):
            Text(value)
        case let .textField(title, binding):
            TextField(title, text: binding)
        case let .toggle(title, binding):
            Toggle(title, isOn: binding)
        case let .button(title, action):
            Button(title, action: action)
        case .divider:
            Divider()
        case let .spacer(minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })
        case let .scrollView(axis, children):
            ScrollView(axes(axis)) {
                ForEach(children) { MarkupNodeView(node: $0) }
            }
        case let .custom(registration, properties, children):
            registration.render(MarkupComponentContent(
                values: properties.values,
                bindings: properties.bindings,
                actions: properties.actions,
                children: children.map { AnyView(MarkupNodeView(node: $0).id($0.id)) }
            ))
        }
    }

    private func horizontalAlignment(_ name: String) -> HorizontalAlignment {
        switch name {
        case "leading": .leading
        case "trailing": .trailing
        default: .center // Exhaustively validated before rendering.
        }
    }

    private func verticalAlignment(_ name: String) -> VerticalAlignment {
        switch name {
        case "top": .top
        case "bottom": .bottom
        case "firstTextBaseline": .firstTextBaseline
        case "lastTextBaseline": .lastTextBaseline
        default: .center // Exhaustively validated before rendering.
        }
    }

    private func axes(_ name: String) -> Axis.Set {
        switch name {
        case "horizontal": .horizontal
        case "both": [.horizontal, .vertical]
        default: .vertical // Exhaustively validated before rendering.
        }
    }
}
