import NativeMarkupCore

enum MarkupVocabulary {
    private static func value(_ type: MarkupValueType, required: Bool = false) -> MarkupPropertySpec {
        MarkupPropertySpec(type: type, required: required)
    }

    static let components: [String: MarkupElementSpec] = [
        "VStack": .init(properties: ["spacing": value(.number), "alignment": value(.string)], allowsChildren: true),
        "HStack": .init(properties: ["spacing": value(.number), "alignment": value(.string)], allowsChildren: true),
        "Text": .init(properties: ["value": value(.string, required: true)]),
        "TextField": .init(properties: [
            "title": value(.string),
            "text": .init(type: .string, kind: .binding, required: true),
        ]),
        "Toggle": .init(properties: [
            "title": value(.string, required: true),
            "isOn": .init(type: .bool, kind: .binding, required: true),
        ]),
        "Button": .init(properties: [
            "title": value(.string, required: true),
            "action": .init(type: .string, kind: .action, required: true),
        ]),
        "Divider": .init(),
        "Spacer": .init(properties: ["minLength": value(.number)]),
        "ScrollView": .init(properties: ["axis": value(.string)], allowsChildren: true),
    ]

    static let modifiers: [String: MarkupElementSpec] = [
        "Padding": .init(properties: ["length": value(.number, required: true)]),
        "Frame": .init(properties: [
            "width": value(.number), "height": value(.number),
            "maxWidth": value(.number), "maxHeight": value(.number),
        ]),
        "Background": .init(properties: ["color": value(.string, required: true)]),
        "ForegroundStyle": .init(properties: ["color": value(.string, required: true)]),
        "Font": .init(properties: ["style": value(.string, required: true)]),
        "Disabled": .init(properties: ["value": value(.bool, required: true)]),
        "Opacity": .init(properties: ["value": value(.number, required: true)]),
    ]
}
