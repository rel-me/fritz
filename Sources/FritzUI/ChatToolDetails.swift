import SwiftUI

public struct ChatToolDetails<Code: View>: View {
    private let title: String
    private let detail: String?
    private let status: String
    private let arguments: String
    private let result: String?
    private let outputTruncated: Bool
    private let code: (String) -> Code

    public init(title: String, detail: String? = nil, status: String,
                arguments: String, result: String? = nil, outputTruncated: Bool = false,
                @ViewBuilder code: @escaping (String) -> Code) {
        self.title = title
        self.detail = detail
        self.status = status
        self.arguments = arguments
        self.result = result
        self.outputTruncated = outputTruncated
        self.code = code
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                if let detail = detail {
                    Text(detail).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Text(status).font(.caption)
                Text("Arguments").font(.subheadline.weight(.semibold))
                code(arguments)
                if let result = result {
                    Text("Result").font(.subheadline.weight(.semibold))
                    code(result)
                }
                if outputTruncated {
                    Label("Some output was omitted or truncated.", systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(width: 480)
        .frame(maxHeight: 560)
    }

}
