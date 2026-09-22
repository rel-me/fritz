import Foundation

struct LocalModelHardware: Sendable {
    let memoryGB: Int
    let appleSilicon: Bool

    static var current: Self {
        #if arch(arm64)
        let appleSilicon = true
        #else
        let appleSilicon = false
        #endif
        return Self(
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            appleSilicon: appleSilicon
        )
    }

    var summary: String {
        "\(appleSilicon ? "Apple silicon" : "Intel Mac") · \(memoryGB) GB memory"
    }

}

struct NativeModelDescriptor: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let size: UInt64
    let memoryGB: Int
    let licenseURL: URL

    private enum CodingKeys: String, CodingKey {
        case id, name, size
        case memoryGB = "memory_gb", licenseURL = "license_url"
    }

    var model: DiscoveredAIModel { .init(id: id, displayName: name) }
    var downloadSummary: String {
        String(format: "%.2f GB download · %d GB RAM recommended", Double(size) / 1_000_000_000, memoryGB)
    }

    static let catalog: [Self] = {
        struct Catalog: Decodable { let models: [NativeModelDescriptor] }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "LocalModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              !catalog.models.isEmpty else {
            preconditionFailure("Missing or invalid bundled local model catalog")
        }
        return catalog.models
    }()
}

