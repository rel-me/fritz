import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses a versioned document and validates its complete host-facing contract before returning it.
public struct MarkupParser: Sendable {
    public let schema: MarkupSchema
    public let variables: [String: MarkupValueType]
    public let actions: Set<String>

    public init(schema: MarkupSchema, variables: [String: MarkupValueType] = [:], actions: Set<String> = []) {
        self.schema = schema
        self.variables = variables
        self.actions = actions
    }

    public func parse(_ source: String) throws -> MarkupDocument {
        guard source.utf8.count <= 262_144 else {
            throw MarkupDiagnostic("Document exceeds the 256 KiB limit.")
        }
        try validateEncoding(source)
        // Input is a Swift String, and is re-encoded as UTF-8 below. Reject declarations
        // before Foundation can expand any entities, including internal DTD entities.
        let uppercase = source.uppercased()
        guard !uppercase.contains("<!DOCTYPE"), !uppercase.contains("<!ENTITY") else {
            throw MarkupDiagnostic("DTD and entity declarations are not supported.")
        }
        let parser = XMLParser(data: Data(source.utf8))
        let builder = DocumentBuilder()
        parser.delegate = builder
        parser.shouldResolveExternalEntities = false
        let parsed = parser.parse()
        if let diagnostic = builder.diagnostic { throw diagnostic }
        guard parsed, let interface = builder.root else {
            throw MarkupDiagnostic(
                parser.parserError?.localizedDescription ?? "The document is not valid XML.",
                location: .init(line: parser.lineNumber, column: parser.columnNumber)
            )
        }
        guard interface.name == "Interface" else {
            throw error("The document root must be Interface.", at: interface)
        }
        guard interface.attributes.keys.allSatisfy({ $0 == "version" }), interface.attributes["version"] == "1" else {
            throw error("Interface requires version=\"1\" and supports no other attributes.", at: interface)
        }
        guard interface.children.count == 1, let rawRoot = interface.children.first else {
            throw error("Interface must contain exactly one root component.", at: interface)
        }
        var ids: Set<String> = []
        return MarkupDocument(root: try node(rawRoot, ids: &ids))
    }

    private func validateEncoding(_ source: String) throws {
        var prefix = source[...]
        if prefix.first == "\u{FEFF}" { prefix.removeFirst() }
        guard prefix.hasPrefix("<?xml"), prefix.dropFirst(5).first?.isWhitespace == true,
              let end = prefix.range(of: "?>") else { return }
        let declaration = String(prefix[..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: #"\bencoding\s*=\s*(['"])([^'"]+)\1"#, options: .caseInsensitive)
        guard let match = pattern.firstMatch(in: declaration, range: NSRange(location: 0, length: declaration.utf16.count)),
              let encodingRange = Range(match.range(at: 2), in: declaration) else { return }
        guard declaration[encodingRange].lowercased() == "utf-8" else {
            throw MarkupDiagnostic("Markup source must use UTF-8; remove the encoding declaration or set encoding=\"UTF-8\".", location: .init(line: 1, column: 1))
        }
    }

    private func node(_ raw: RawElement, ids: inout Set<String>) throws -> MarkupNode {
        guard let spec = schema.components[raw.name] else {
            throw error("Unknown component '\(raw.name)'.", at: raw)
        }
        guard let id = raw.attributes["id"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error("Component '\(raw.name)' requires a nonempty id.", at: raw)
        }
        guard ids.insert(id).inserted else {
            throw error("Duplicate component id '\(id)'.", at: raw)
        }
        let parsedProperties = try properties(raw, spec: spec, permitsID: true)
        var children: [MarkupNode] = []
        var modifiers: [MarkupModifier] = []
        var hasModifiers = false
        for child in raw.children {
            if child.name == "Modifiers" {
                guard !hasModifiers, child.attributes.isEmpty else {
                    throw error("A component may have one Modifiers element with no attributes.", at: child)
                }
                hasModifiers = true
                modifiers = try child.children.map { modifier in
                    guard let spec = schema.modifiers[modifier.name] else {
                        throw error("Unknown modifier '\(modifier.name)'.", at: modifier)
                    }
                    guard modifier.children.isEmpty else {
                        throw error("Modifier '\(modifier.name)' cannot contain child elements.", at: modifier)
                    }
                    return MarkupModifier(
                        name: modifier.name,
                        properties: try properties(modifier, spec: spec, permitsID: false),
                        location: modifier.location
                    )
                }
            } else {
                guard spec.allowsChildren else {
                    throw error("Component '\(raw.name)' does not accept child components.", at: child)
                }
                children.append(try node(child, ids: &ids))
            }
        }
        return MarkupNode(id: id, name: raw.name, properties: parsedProperties, children: children, modifiers: modifiers, location: raw.location)
    }

    private func properties(_ raw: RawElement, spec: MarkupElementSpec, permitsID: Bool) throws -> [String: MarkupPropertyValue] {
        var result: [String: MarkupPropertyValue] = [:]
        for name in raw.attributes.keys.sorted() {
            if name == "id" && permitsID { continue }
            guard let property = spec.properties[name], let source = raw.attributes[name] else {
                throw error("Unknown attribute '\(name)' on '\(raw.name)'.", at: raw)
            }
            do {
                result[name] = try propertyValue(source, spec: property)
            } catch let diagnostic as MarkupDiagnostic {
                throw error("\(raw.name).\(name): \(diagnostic.message)", at: raw)
            }
        }
        for name in spec.properties.keys.sorted() {
            if spec.properties[name]?.required == true && result[name] == nil {
                throw error("Missing required attribute '\(name)' on '\(raw.name)'.", at: raw)
            }
        }
        return result
    }

    private func propertyValue(_ source: String, spec: MarkupPropertySpec) throws -> MarkupPropertyValue {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        switch spec.kind {
        case .action:
            guard actions.contains(trimmed) else {
                throw MarkupDiagnostic("Unknown action '\(trimmed)'.")
            }
            return .action(trimmed)
        case .binding:
            guard trimmed.hasPrefix("$") else {
                throw MarkupDiagnostic("A writable binding must use $variable syntax.")
            }
            return try binding(String(trimmed.dropFirst()), type: spec.type)
        case .value:
            if trimmed.hasPrefix("$") {
                let name = String(trimmed.dropFirst())
                _ = try binding(name, type: spec.type)
                return .expression(.reference(name))
            }
            if trimmed.hasPrefix("{{") {
                guard trimmed.hasSuffix("}}") else {
                    throw MarkupDiagnostic("An expression must end with }}.")
                }
                let expression = try MarkupExpression.parse(String(trimmed.dropFirst(2).dropLast(2)))
                let actual = try expression.typecheck(variables: variables)
                guard actual == spec.type else {
                    throw MarkupDiagnostic("Expected \(spec.type.rawValue), received \(actual.rawValue).")
                }
                return .expression(expression)
            }
            switch spec.type {
            case .string: return .literal(.string(source))
            case .number:
                guard let number = Double(trimmed), number.isFinite else {
                    throw MarkupDiagnostic("Expected a finite number.")
                }
                return .literal(.number(number))
            case .bool:
                guard trimmed == "true" || trimmed == "false" else {
                    throw MarkupDiagnostic("Expected true or false.")
                }
                return .literal(.bool(trimmed == "true"))
            }
        }
    }

    private func binding(_ name: String, type: MarkupValueType) throws -> MarkupPropertyValue {
        guard let actual = variables[name] else {
            throw MarkupDiagnostic("Unknown binding '\(name)'.")
        }
        guard actual == type else {
            throw MarkupDiagnostic("Binding '\(name)' has type \(actual.rawValue); expected \(type.rawValue).")
        }
        return .binding(name)
    }

    private func error(_ message: String, at raw: RawElement) -> MarkupDiagnostic {
        MarkupDiagnostic(message, location: raw.location)
    }
}

private final class RawElement {
    let name: String
    let attributes: [String: String]
    let location: MarkupSourceLocation
    var children: [RawElement] = []

    init(name: String, attributes: [String: String], location: MarkupSourceLocation) {
        self.name = name
        self.attributes = attributes
        self.location = location
    }
}

private final class DocumentBuilder: NSObject, XMLParserDelegate {
    var root: RawElement?
    var diagnostic: MarkupDiagnostic?
    private var stack: [RawElement] = []
    private var elementCount = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard diagnostic == nil else { return }
        elementCount += 1
        guard elementCount <= 2_000 else {
            fail("Document exceeds the 2000-element limit.", parser: parser)
            return
        }
        guard stack.count < 64 else {
            fail("Document exceeds the depth limit of 64.", parser: parser)
            return
        }
        let element = RawElement(name: elementName, attributes: attributeDict, location: .init(line: parser.lineNumber, column: parser.columnNumber))
        if let parent = stack.last {
            parent.children.append(element)
        } else if root == nil {
            root = element
        } else {
            fail("The document must have exactly one root element.", parser: parser)
            return
        }
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if !stack.isEmpty { stack.removeLast() }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("Text content must use component attributes, such as Text value=\"…\".", parser: parser)
        }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        fail("CDATA content is not supported; use component attributes.", parser: parser)
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        fail("Processing instructions are not supported.", parser: parser)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        fail("External entities are not supported.", parser: parser)
        return nil
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail("Entity declarations are not supported.", parser: parser)
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail("Entity declarations are not supported.", parser: parser)
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if diagnostic == nil {
            diagnostic = MarkupDiagnostic(parseError.localizedDescription, location: .init(line: parser.lineNumber, column: parser.columnNumber))
        }
    }

    private func fail(_ message: String, parser: XMLParser) {
        guard diagnostic == nil else { return }
        diagnostic = MarkupDiagnostic(message, location: .init(line: parser.lineNumber, column: parser.columnNumber))
        parser.abortParsing()
    }
}
