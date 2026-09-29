import SwiftUI

/// Provider setup action for the chat composer's accessory controls.
public struct ChatProviderSetupButton: View {
    private let action: () -> Void

    public init(action: @escaping () -> Void) {
        self.action = action
    }

    public var body: some View {
        Button("Add Provider", action: action)
            .font(.body)
            .controlSize(.regular)
            .buttonStyle(FritzButtonStyle())
            .help("Add Provider")
    }
}
