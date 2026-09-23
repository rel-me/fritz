import Foundation
import Fritz

extension CommandLineInstaller {
    static let installedCLIURL = URL(fileURLWithPath: "/Applications/Fritz.app/Contents/Resources/fritz")

    init() {
        self.init(cliURL: Self.installedCLIURL)
    }
}
