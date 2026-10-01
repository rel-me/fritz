import NativeMarkupCore
import XCTest

final class MarkupContractTests: XCTestCase {
    private let parser = MarkupParser(
        schema: MarkupSchema(
            components: [
                "VStack": .init(properties: ["spacing": .init(type: .number)], allowsChildren: true),
                "Text": .init(properties: ["value": .init(type: .string, required: true)]),
                "TextField": .init(properties: ["text": .init(type: .string, kind: .binding, required: true)]),
                "Button": .init(properties: ["action": .init(type: .string, kind: .action, required: true)])
            ],
            modifiers: [
                "Padding": .init(properties: ["length": .init(type: .number, required: true)]),
                "Background": .init(properties: ["color": .init(type: .string, required: true)]),
                "Disabled": .init(properties: ["value": .init(type: .bool, required: true)])
            ]
        ),
        variables: ["note": .string, "enabled": .bool, "width": .number],
        actions: ["save"]
    )

    func testDocumentPreservesIdentityModifierOrderAndBindingCapabilities() throws {
        let document = try parser.parse("""
        <Interface version="1">
          <VStack id="root" spacing="12">
            <Text id="preview" value="$note"/>
            <TextField id="editor" text="$note"/>
            <Button id="save" action="save">
              <Modifiers><Disabled value="{{ !enabled || isEmpty(note) }}"/></Modifiers>
            </Button>
            <Modifiers><Padding length="16"/><Background color="blue"/><Padding length="4"/></Modifiers>
          </VStack>
        </Interface>
        """)
        XCTAssertEqual(document.root.children.map(\.id), ["preview", "editor", "save"])
        XCTAssertEqual(document.root.modifiers.map(\.name), ["Padding", "Background", "Padding"])
        let preview = try XCTUnwrap(document.root.children[0].properties["value"])
        guard case .expression = preview else { return XCTFail("A readable value must not expose a writable binding.") }
        XCTAssertEqual(try preview.evaluate(variables: ["note": .string("A & B")]), .string("A & B"))
        guard case .binding("note")? = document.root.children[1].properties["text"] else {
            return XCTFail("The editor must retain the explicit writable binding.")
        }
        guard case .action("save")? = document.root.children[2].properties["action"] else {
            return XCTFail("The button must retain the registered host action.")
        }
        let disabled = try XCTUnwrap(document.root.children[2].modifiers[0].properties["value"])
        XCTAssertEqual(try disabled.evaluate(variables: ["enabled": .bool(true), "note": .string("")]), .bool(true))
        XCTAssertEqual(try disabled.evaluate(variables: ["enabled": .bool(true), "note": .string("Draft")]), .bool(false))
    }

    func testRejectsInvalidHostContractsAtTheSourceLocation() {
        let cases: [(String, String)] = [
            (#"<Mystery id="x"/>"#, "Unknown component"),
            (#"<Text id="x" value="hello" typo="x"/>"#, "Unknown attribute"),
            (#"<Text value="hello"/>"#, "requires a nonempty id"),
            (#"<Text id="x"/>"#, "Missing required attribute"),
            (#"<VStack id="x"><Text id="x" value="hello"/></VStack>"#, "Duplicate component id"),
            (#"<Text id="x" value="hello"><Text id="y" value="child"/></Text>"#, "does not accept child"),
            (#"<Text id="x" value="$unknown"/>"#, "Unknown binding"),
            (#"<TextField id="x" text="$enabled"/>"#, "expected string"),
            (#"<TextField id="x" text="note"/>"#, "writable binding"),
            (#"<TextField id="x" text="{{ note }}"/>"#, "writable binding"),
            (#"<Button id="x" action="delete"/>"#, "Unknown action"),
            (#"<Text id="x" value="{{ enabled }}"/>"#, "Expected string, received bool"),
            (#"<Text id="x" value="{{ missing }}"/>"#, "Unknown variable"),
            (#"<Text id="x" value="{{ note"/>"#, "must end with"),
            (#"<VStack id="x" spacing="nan"/>"#, "finite number"),
            (#"<VStack id="x"><Modifiers><Disabled value="yes"/></Modifiers></VStack>"#, "Expected true or false"),
            (#"<VStack id="x"><Modifiers><Unknown/></Modifiers></VStack>"#, "Unknown modifier"),
            (#"<VStack id="x"><Modifiers/><Modifiers/></VStack>"#, "one Modifiers element"),
            (#"<VStack id="x"><Modifiers id="m"/></VStack>"#, "no attributes"),
            (#"<VStack id="x"><Modifiers><Padding id="m" length="2"/></Modifiers></VStack>"#, "Unknown attribute"),
            (#"<VStack id="x"><Modifiers><Padding length="2"><Text id="y" value="child"/></Padding></Modifiers></VStack>"#, "cannot contain child"),
            (#"<Text id="x" value="hello">unexpected text</Text>"#, "Text content must use")
        ]
        for (component, expected) in cases {
            let source = "<Interface version=\"1\">\n  \(component)\n</Interface>"
            XCTAssertThrowsError(try parser.parse(source), component) { error in
                guard let diagnostic = error as? MarkupDiagnostic else { return XCTFail("Expected a source diagnostic.") }
                XCTAssertTrue(diagnostic.message.contains(expected), diagnostic.description)
                XCTAssertNotNil(diagnostic.location, component)
                XCTAssertGreaterThanOrEqual(diagnostic.location?.line ?? 0, 2)
            }
        }
    }

    func testRejectsUnsupportedDocumentsAndEntityDeclarations() throws {
        let cases: [(String, String)] = [
            (#"<Interface version="2"><VStack id="root"/></Interface>"#, "version"),
            (#"<Interface><VStack id="root"/></Interface>"#, "version"),
            (#"<Interface version="1" extra="x"><VStack id="root"/></Interface>"#, "no other attributes"),
            (#"<VStack id="root"/>"#, "root must be Interface"),
            (#"<Interface version="1"/>"#, "exactly one root"),
            (#"<Interface version="1"><VStack id="a"/><VStack id="b"/></Interface>"#, "exactly one root"),
            (#"<!DOCTYPE Interface [<!ENTITY value "expanded">]><Interface version="1"><Text id="x" value="&value;"/></Interface>"#, "DTD and entity"),
            (#"<!DOCTYPE Interface SYSTEM "file:///private/unknown"><Interface version="1"><VStack id="root"/></Interface>"#, "DTD and entity"),
            (#"<?host action="save"?><Interface version="1"><VStack id="root"/></Interface>"#, "Processing instructions")
        ]
        for (source, expected) in cases {
            assertDiagnostic(expected) { _ = try self.parser.parse(source) }
        }
        let escaped = try parser.parse(#"<Interface version="1"><Text id="x" value="A &amp; B"/></Interface>"#)
        XCTAssertEqual(try escaped.root.properties["value"]?.evaluate(variables: [:]), .string("A & B"))
        let money = try parser.parse(#"<Interface version="1"><Text id="x" value="{{ '$5' }}"/></Interface>"#)
        XCTAssertEqual(try money.root.properties["value"]?.evaluate(variables: [:]), .string("$5"))
        XCTAssertThrowsError(try parser.parse(#"<Interface version="1"><VStack id="root"></Interface>"#))
    }

    func testEnforcesInputBudgetsBeforeRendering() {
        let oversized = String(repeating: " ", count: 262_145)
        assertDiagnostic("256 KiB") { _ = try self.parser.parse(oversized) }
        let opening = (0..<65).map { "<VStack id=\"node\($0)\">" }.joined()
        let deep = "<Interface version=\"1\">" + opening + String(repeating: "</VStack>", count: 65) + "</Interface>"
        assertDiagnostic("depth limit") { _ = try self.parser.parse(deep) }
        let many = (0..<2_000).map { "<Text id=\"node\($0)\" value=\"x\"/>" }.joined()
        assertDiagnostic("2000-element") {
            _ = try self.parser.parse("<Interface version=\"1\"><VStack id=\"root\">" + many + "</VStack></Interface>")
        }
        assertDiagnostic("4096-byte") { _ = try MarkupExpression.parse(String(repeating: " ", count: 4_097)) }
        assertDiagnostic("512-token") { _ = try MarkupExpression.parse(Array(repeating: "1", count: 258).joined(separator: "+")) }
        assertDiagnostic("depth limit") { _ = try MarkupExpression.parse(String(repeating: "!", count: 65) + "true") }
    }

    func testReadReferencesUseRegisteredKeysWithoutParsingThemAsCode() throws {
        let numericKeyParser = MarkupParser(schema: parser.schema, variables: ["123": .number])
        let document = try numericKeyParser.parse(#"<Interface version="1"><VStack id="root" spacing="$123"/></Interface>"#)
        let spacing = try XCTUnwrap(document.root.properties["spacing"])
        XCTAssertEqual(try spacing.evaluate(variables: ["123": .number(88)]), .number(88))
    }

    func testRejectsEncodingDeclarationsThatDisagreeWithUTF8Source() throws {
        let source = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <Interface version="1"><Text id="text" value="Café"/></Interface>
        """
        assertDiagnostic("UTF-8") { _ = try self.parser.parse(source) }

        let validSource = source.replacingOccurrences(of: "ISO-8859-1", with: "UTF-8")
        let document = try parser.parse(validSource)
        XCTAssertEqual(try document.root.properties["value"]?.evaluate(variables: [:]), .string("Café"))
    }

    func testTypedExpressionsRespectPrecedenceAndLazyBooleanEvaluation() throws {
        let cases: [(String, MarkupValue)] = [
            ("2 + 3 * 4", .number(14)),
            ("(2 + 3) * 4", .number(20)),
            ("20 / 2 / 5", .number(2)),
            ("-2 * 3 + 10 % 3", .number(-5)),
            ("count(note) == 5 && !isEmpty(note)", .bool(true)),
            ("'Hello, ' + note", .string("Hello, Draft")),
            ("false && (1 / 0 > 0)", .bool(false)),
            ("true || (1 / 0 > 0)", .bool(true)),
            ("width >= 80 && width < 100", .bool(true))
        ]
        for (source, expected) in cases {
            let expression = try MarkupExpression.parse(source)
            XCTAssertEqual(try expression.evaluate(variables: ["note": .string("Draft"), "width": .number(88)]), expected, source)
        }
        assertDiagnostic("Division by zero") {
            _ = try MarkupExpression.parse("true && (1 / 0 > 0)").evaluate(variables: [:])
        }
        assertDiagnostic("matching operand types") {
            _ = try MarkupExpression.parse("false && 1").evaluate(variables: [:])
        }
        assertDiagnostic("Unknown function") { _ = try MarkupExpression.parse("readFile('secret')") }
        assertDiagnostic("Unexpected character") { _ = try MarkupExpression.parse("note = 'changed'") }
        assertDiagnostic("requires string") { _ = try MarkupExpression.parse("count(width)").typecheck(variables: ["width": .number]) }
        assertDiagnostic("must be finite") { _ = try MarkupExpression.parse("1e308 * 2").evaluate(variables: [:]) }
        assertDiagnostic("must be a finite") { _ = try MarkupExpression.parse("width").evaluate(variables: ["width": .number(.infinity)]) }
    }

    private func assertDiagnostic(_ text: String, file: StaticString = #filePath, line: UInt = #line, operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard let diagnostic = error as? MarkupDiagnostic else {
                return XCTFail("Expected MarkupDiagnostic, received \(error).", file: file, line: line)
            }
            XCTAssertTrue(diagnostic.message.contains(text), diagnostic.description, file: file, line: line)
        }
    }
}
