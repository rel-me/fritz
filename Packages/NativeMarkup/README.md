# NativeMarkup

An independent Swift package for rendering local XML documents with native
SwiftUI views. Requires Swift 6.3 and macOS 15 or later. Fritz is the first host;
the package has no dependency on Fritz, its stores, its processes, or its styles.
Licensed under AGPL-3.0-only; see [LICENSE](LICENSE).

## Products

| Product | Responsibility |
| --- | --- |
| `NativeMarkupCore` | Bounded XML parsing, typed schema validation, immutable documents, pure expressions, source diagnostics |
| `NativeMarkupUI` | Native component registry, host bindings/actions, ordered modifiers, transactional document installation |
| `NativeMarkupDevelopment` | Opt-in bounded local file loading and live reload |

Add this directory as a standalone SwiftPM path dependency:

```swift
.package(path: "../NativeMarkup")

// Target dependencies:
.product(name: "NativeMarkupUI", package: "NativeMarkup"),
.product(name: "NativeMarkupDevelopment", package: "NativeMarkup")
```

Add the `NativeMarkupCore` product too when defining extension schemas directly.
The package has its own manifest and tests. It can move to its own repository
without importing Fritz code. It is not yet separately published or versioned.
In the Fritz checkout, `make test-swift` includes its tests and uses the shared
build-cache wrapper.

## Embed a document

Retain the context/session with the host's state owner. Register capabilities
before calling `apply(source:)`; a successful apply captures those registrations
for that document. Later registration changes require another successful apply.
Register `String`, `Bool`, and `Double` values with main-actor getter/setter
closures. The state remains owned by the host; retain that owner for the session's
lifetime. The example uses weak captures to avoid an owner/session retain cycle.

```swift
import NativeMarkupUI
import Observation
import SwiftUI

@MainActor @Observable
final class PanelModel {
    var note = ""
    var enabled = true
    let session: MarkupSession

    init(source: String) {
        let context = MarkupContext()
        session = MarkupSession(context: context)
        context.registerBinding("note",
            get: { [weak self] in self?.note ?? "" },
            set: { [weak self] in self?.note = $0 }
        )
        context.registerBinding("enabled",
            get: { [weak self] in self?.enabled ?? false },
            set: { [weak self] in self?.enabled = $0 }
        )
        context.registerAction("clear") { [weak self] in self?.note = "" }
        session.apply(source: source)
    }
}

struct PanelView: View {
    let model: PanelModel // Retained by the host, including while this view is hidden.

    var body: some View {
        VStack(alignment: .leading) {
            MarkupView(session: model.session)
            if let diagnostic = model.session.diagnostic {
                Text(diagnostic).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}
```

Use [Examples/Panel.xml](Examples/Panel.xml) as the source. It uses these two
bindings and the `clear` action. In Fritz, open that file from the right panel,
enter text, then edit and save the XML to see it update in place.

`apply(source:)` returns whether installation succeeded. Invalid source retains
the previous document and reports a diagnostic. For automatic updates, registered
getters must read observable host properties, such as the `@Observable` fields
above. `MarkupView` tracks those live reads and refreshes expressions when the
values change; native controls write through the registered setters. For plain
nonobservable getters, call `session.refresh()` after each host mutation.
Failed expression evaluation retains the last resolved presentation;
it does not roll back host state. Show `session.diagnostic` beside the renderer.

## Document syntax

```xml
<Interface version="1">
  <VStack id="panel" spacing="12" alignment="leading">
    <Text id="heading" value="Notes"/>
    <TextField id="note" title="Note" text="$note"/>
    <Button id="clear" title="Clear" action="clear">
      <Modifiers>
        <Disabled value="{{ !enabled || isEmpty(note) }}"/>
        <Padding length="8"/>
      </Modifiers>
    </Button>
  </VStack>
</Interface>
```

`Interface` requires `version="1"` and exactly one root component. Every component
requires a nonempty, document-unique `id`. A component can have one `Modifiers`
child; modifiers have no IDs and apply in written order. For example, padding
before a background colors the padded area; reversing them changes that result.
Only containers declared to accept children may contain other components.

Text uses attributes: `<Text id="blank" value=""/>` is valid empty text;
`<Text id="label">Hello</Text>` is invalid. Literal string attributes retain their
XML-decoded value. After trimming surrounding whitespace, a value starting with `$` refers to a registered binding;
one starting with `{{` is an expression. To display those prefixes literally,
use a quoted expression: `value="{{ '$5' }}"` or
`value="{{ '{{literal}}' }}"`.

Writable attributes require `$name`. Value attributes also accept `$name` as a
read-only reference, or an expression occupying the whole value as
`{{ expression }}`. Actions contain the registered action name, such as `clear`;
they are not expressions or embedded code. XML escaping still applies: use
`&amp;&amp;` for `&&`, `&lt;` for `<`, and `&quot;` for an attribute's double quote.

### Shipped components

All names and attribute values are case-sensitive. `String`, `Bool`, and `Number`
below mean the runtime's string, boolean, and finite `Double` types. Optional
numeric attributes use SwiftUI's default when omitted.

| Component | Attributes besides required `id` | Children |
| --- | --- | --- |
| `VStack` | Optional `spacing: Number`; `alignment`: `leading`, `center` (default), `trailing` | Yes |
| `HStack` | Optional `spacing: Number`; `alignment`: `top`, `center` (default), `bottom`, `firstTextBaseline`, `lastTextBaseline` | Yes |
| `Text` | Required `value: String` | No |
| `TextField` | Required writable `text: String`; optional `title: String` (default empty) | No |
| `Toggle` | Required `title: String` and writable `isOn: Bool` | No |
| `Button` | Required `title: String` and registered `action` | No |
| `Divider` | None | No |
| `Spacer` | Optional nonnegative `minLength: Number` | No |
| `ScrollView` | `axis`: `vertical` (default), `horizontal`, `both` | Yes |

Place a stack inside `ScrollView` when its children need vertical or horizontal
layout; the scroll container does not introduce a stack for you.

### Shipped modifiers

| Modifier | Attributes |
| --- | --- |
| `Padding` | Required `length: Number`, applied to all edges |
| `Frame` | Optional nonnegative `width`, `height`, `maxWidth`, `maxHeight`; finite numbers only |
| `Background` | Required `color: String` |
| `ForegroundStyle` | Required `color: String` |
| `Font` | Required `style: String` |
| `Disabled` | Required `value: Bool` |
| `Opacity` | Required `value: Number` in `0...1` |

Colors: `primary`, `secondary`, `accent`, `clear`, `red`, `green`, `blue`, `orange`,
`yellow`, `purple`, `pink`, `gray`, `white`, `black`. Fonts: `largeTitle`, `title`,
`title2`, `title3`, `headline`, `subheadline`, `body`, `callout`, `footnote`,
`caption`, `caption2`. Other names, arbitrary colors, and infinite frame sizes
require a compiled extension rather than silently falling back.

### Expressions

Expressions support registered variable names, finite numbers, `true`/`false`,
single- or double-quoted strings, and parentheses. Names such as `form.note` are
exact registered keys, not object property access. String escapes are `\n`,
`\r`, `\t`, `\\`, `\"`, and `\'`.

Expression identifiers use dot-separated segments, each starting with an ASCII
letter or underscore followed by ASCII letters, digits, or underscores. `true`
and `false` are reserved literals. Direct `$name` references instead resolve the
registered key literally.

| Operations | Meaning |
| --- | --- |
| `!`, unary `-` | Boolean negation; numeric negation |
| `*`, `/`, `%`, `+`, `-` | Numeric arithmetic; `+` also joins two strings |
| `<`, `<=`, `>`, `>=` | Numeric comparisons |
| `==`, `!=` | Equality between values of the same type |
| `&&`, `\|\|` | Boolean logic with short-circuit evaluation |
| `isEmpty(string)`, `count(string)` | Boolean emptiness; character count as a number |

Precedence follows the table from unary through boolean operations, with `* / %`
before `+ -` and `&&` before `||`. Types must match; there is no implicit conversion
from a number to text. Division by zero, non-finite arithmetic, unknown functions,
and incompatible types produce diagnostics. Expressions have no assignment,
loops, action calls, or access to Swift APIs.

## Compiled extensions

Import `NativeMarkupCore` to define a typed registration schema. Perform these
registrations on the main actor before applying a document:

```swift
import NativeMarkupCore

context.registerComponent("Badge", specification: .init(properties: [
    "title": .init(type: .string, required: true)
])) { content in
    guard case let .string(title)? = content.values["title"] else {
        preconditionFailure("The registration requires a validated string title.")
    }
    return AnyView(Text(title).font(.caption).padding(4))
}

context.registerModifier("CapsuleBorder", specification: .init()) { view, _ in
    AnyView(view.overlay(Capsule().stroke(.secondary)))
}
```

The corresponding document node is:

```xml
<Badge id="status" title="Ready">
  <Modifiers><CapsuleBorder/></Modifiers>
</Badge>
```

`MarkupElementSpec` declares properties and `allowsChildren`. A property specifies
its type (`.string`, `.bool`, `.number`), whether it is required, and its kind:
`.value` (default), `.binding`, or `.action`. `MarkupComponentContent` supplies
resolved `values`, typed `bindings`, named action closures, and rendered `children`.
Modifier callbacks receive the same inputs with no children. Native extension
implementations own any additional semantic validation and lifecycle behavior.
Built-in component and modifier names are reserved; attempts to replace them fail
at document application.

## Live files

Create and retain `MarkupFileLoader`, then call `await loader.open(fileURL)`.
It exposes observable `source`, `diagnostic`, and `fileURL`. In the host view,
apply source changes to its persistent session, including the current source when
the view appears:

```swift
MarkupView(session: session)
    .onChange(of: loader.source, initial: true) { _, source in
        if let source { session.apply(source: source) }
    }
```

Display both loader and session diagnostics. The host owns any task it creates to
call `open`, and calls `loader.stop()` when that ownership ends. Opening a file
performs an initial read and starts watching; it does not suspend for the entire
watch lifetime. Nothing starts at module import.

The loader reads local UTF-8 regular files on a separate actor, with a 256 KiB
bound. It polls every 250 ms and requires two matching reads before publishing a
change. This handles atomic editor saves without depending on inode lifetime or
timestamp precision. Read failures retain the last source and recover when the
selected file becomes readable. Switching files and stopping invalidate pending
reads. This is a development tool for explicitly selected local files.

## Validation and scope

Unknown elements, attributes, bindings, actions, incompatible types, duplicate
IDs, invalid enum values, and unsupported versions fail with diagnostics. XML
source errors include their location when available. DTDs, custom entities,
processing instructions, CDATA, and inline element text are unsupported; predefined
XML escapes are allowed. Documents are limited to 256 KiB, 2,000 XML elements,
and depth 64. Each expression is limited to 4,096 bytes, 512 tokens, depth 64,
and 256 KiB for concatenated string results.

Stable IDs preserve identity within compatible structural positions. Changing a
component type, modifier structure, or parent can still reset native focus or
local view state. Host bindings survive reloads; arbitrary tree reconciliation is
not guaranteed.

This version interprets a bounded vocabulary backed by compiled SwiftUI code.
It supports scalar host bindings, pure expressions, and synchronous named actions.
It does not execute embedded Swift or JavaScript, compile new native code, persist
application state, or own asynchronous application tasks. New compiled extensions
require rebuilding the host; supported document edits do not.

Collections/templates, conditional nodes, named content slots, navigation,
sheets, focus, gestures, accessibility modifiers, animation, and environment or
preference keys do not have built-in markup adapters yet. Hosts can expose selected
behavior through compiled components and modifiers. Scenes, commands, toolbars,
and table columns require their own typed builder contexts; they cannot all be
represented as ordinary `View` nodes. Future source generation must compile its
output before execution and preserve the runtime language's meaning.

## Design references

- [LiveView Native](https://github.com/liveview-native/liveview-client-swiftui):
  SwiftUI markup, component registries, and modifier expressions.
- [Layout](https://github.com/nicklockwood/layout): historical UIKit/XML and
  expression-driven live layouts.
- [DynamicUI](https://github.com/0xWDG/DynamicUI): JSON-driven native components.
- [Swift compiler architecture](https://www.swift.org/documentation/swift-compiler/):
  parsing, semantic analysis, and execution are distinct concerns.

These are architectural references, not package dependencies.
