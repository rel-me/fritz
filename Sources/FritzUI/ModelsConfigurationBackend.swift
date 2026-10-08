import Fritz
import Foundation
import Observation

public enum ModelsImportPolicy: String, CaseIterable {
    case skip, overwrite
}

/// Host persistence and networking. Configuration UI belongs to FritzUI.
@MainActor public protocol ModelsProviderStore: AnyObject, Observable {
    var connections: [ProviderConnection] { get }
    var defaultConnectionID: UUID? { get }
    var catalog: [UUID: [DiscoveredAIModel]] { get }
    var discoveryErrors: [UUID: String] { get }
    var isLoading: Bool { get }
    var error: String? { get set }
    var recentIDs: [String] { get }
    var nativeModelCatalog: [NativeModelDescriptor] { get }
    func refresh() async
    func save(_ connection: ProviderConnection, key: String, makeDefault: Bool) async throws
    func remove(_ connection: ProviderConnection) async
    func makeDefault(_ connection: ProviderConnection) async
    func importProviders(_ text: String, policy: ModelsImportPolicy) async throws
    func exportProviders(_ connections: [ProviderConnection], includeKeys: Bool) throws -> String
    func discoverModels(_ connection: ProviderConnection, key: String) async throws -> [DiscoveredAIModel]
    func modelEvents(category: AIModelCategory, modelID: String, install: Bool, directory: URL?,
                     requestID: String) -> AsyncThrowingStream<Data, Error>
    func cancelModelRequest(_ requestID: String)
}

public enum ModelsStartPolicy: String, Codable, CaseIterable, Identifiable {
    case firstUse, appStart
    public var id: String { rawValue }
    public var title: String { self == .firstUse ? "First use" : "App start" }
}

public struct ModelsRuntimeSession {
    public enum Status {
        case stopped, starting, running, stopping, failed
        public var title: String {
            switch self {
            case .stopped: "Stopped"
            case .starting: "Starting"
            case .running: "Running"
            case .stopping: "Stopping"
            case .failed: "Failed"
            }
        }
    }
    public var status: Status
    public var processID: Int32?
    public var address: String?
    public var error: String?
    public init(status: Status = .stopped, processID: Int32? = nil,
                address: String? = nil, error: String? = nil) {
        self.status = status; self.processID = processID
        self.address = address; self.error = error
    }
}

/// Host process ownership stays outside the UI package.
@MainActor public protocol ModelsRuntimeStore: AnyObject, Observable {
    var installedIDs: Set<String> { get }
    var sessions: [String: ModelsRuntimeSession] { get }
    var service: ModelsRuntimeSession { get }
    var isLoading: Bool { get }
    var error: String? { get }
    var policyError: String? { get }
    func policy(for modelID: String) -> ModelsStartPolicy
    func setPolicy(_ policy: ModelsStartPolicy, for modelID: String) throws
    func refresh() async
    func start(_ modelID: String)
    func stop(_ modelID: String)
}

public struct ModelsEditorSelection: Identifiable {
    public let id = UUID()
    public var connection: ProviderConnection?
    public var preset: AIProviderPreset?
    public init(connection: ProviderConnection? = nil, preset: AIProviderPreset? = nil) {
        self.connection = connection; self.preset = preset
    }
}
