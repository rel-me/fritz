import Foundation

public struct LocalModelHardware: Sendable {
    public let memoryGB: Int
    public let appleSilicon: Bool
    public init(memoryGB: Int, appleSilicon: Bool) {
        self.memoryGB = memoryGB
        self.appleSilicon = appleSilicon
    }

    public static var current: Self {
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

    public var summary: String {
        "\(appleSilicon ? "Apple silicon" : "Intel Mac") · \(memoryGB) GB memory"
    }

}

public struct NativeModelDescriptor: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let size: UInt64
    public let memoryGB: Int
    public let licenseURL: URL

    public init(id: String, name: String, size: UInt64, memoryGB: Int, licenseURL: URL) {
        self.id = id
        self.name = name
        self.size = size
        self.memoryGB = memoryGB
        self.licenseURL = licenseURL
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, size
        case memoryGB = "memory_gb", licenseURL = "license_url"
    }

    public var model: DiscoveredAIModel { .init(id: id, displayName: name) }
    public var downloadSummary: String {
        String(format: "%.2f GB download · %d GB RAM recommended", Double(size) / 1_000_000_000, memoryGB)
    }

    public static let catalog: [Self] = {
        struct Catalog: Decodable { let models: [NativeModelDescriptor] }
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "LocalModels", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data),
              !catalog.models.isEmpty else {
            preconditionFailure("Missing or invalid bundled local model catalog")
        }
        return catalog.models
    }()
}

