import SwiftUI

public struct LocalModelListItem<ID: Hashable>: Identifiable {
  public let id: ID
  public let name: String
  public let modelID: String
  public let status: String
  public let isRunning: Bool
  public let processID: Int32?
  public let detail: String?
  public let errorMessage: String?

  public init(
    id: ID, name: String, modelID: String, status: String, isRunning: Bool,
    processID: Int32? = nil, detail: String? = nil, errorMessage: String? = nil
  ) {
    self.id = id
    self.name = name
    self.modelID = modelID
    self.status = status
    self.isRunning = isRunning
    self.processID = processID
    self.detail = detail
    self.errorMessage = errorMessage
  }
}

/// The installed-model list used by Fritz and its host applications. Hosts own
/// model inventory, process lifetimes, and the actions appropriate to each row.
public struct LocalModelsList<ID: Hashable, Actions: View>: View {
  let models: [LocalModelListItem<ID>]
  let actions: (ID) -> Actions

  public init(
    models: [LocalModelListItem<ID>], @ViewBuilder actions: @escaping (ID) -> Actions
  ) {
    self.models = models
    self.actions = actions
  }

  public var body: some View {
    List(models) { model in
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(model.name).font(.headline)
          Text(model.modelID).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(alignment: .leading, spacing: 3) {
          Label(model.status, systemImage: model.isRunning ? "circle.fill" : "circle")
            .foregroundStyle(model.isRunning ? .green : .secondary)
          if let pid = model.processID {
            Text("PID \(pid)").font(.caption).foregroundStyle(.secondary)
          }
          if let detail = model.detail {
            Text(detail).font(.caption).textSelection(.enabled)
          }
          if let error = model.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2).help(error)
          }
        }
        .frame(width: 190, alignment: .leading)
        actions(model.id)
          .buttonStyle(FritzButtonStyle(.inline))
          .frame(width: 125, alignment: .trailing)
      }
      .padding(.vertical, 6)
    }
    .listStyle(.plain)
  }
}
