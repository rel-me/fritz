import SwiftUI

public struct LocalModelSessionItem<ID: Hashable>: Identifiable {
  public let id: ID
  public let modelID: String
  public let modelName: String
  public let scope: String
  public let processID: Int32?
  public let isRunning: Bool
  public let isResponding: Bool
  public let canStart: Bool
  public let status: String
  public let errorMessage: String?

  public init(
    id: ID, modelID: String, modelName: String, scope: String, processID: Int32?, isRunning: Bool,
    isResponding: Bool, canStart: Bool, status: String, errorMessage: String?
  ) {
    self.id = id
    self.modelID = modelID
    self.modelName = modelName
    self.scope = scope
    self.processID = processID
    self.isRunning = isRunning
    self.isResponding = isResponding
    self.canStart = canStart
    self.status = status
    self.errorMessage = errorMessage
  }
}

/// Process controls invoke host callbacks and never retain or launch a runtime.
public struct LocalModelSessionsList<ID: Hashable>: View {
  let sessions: [LocalModelSessionItem<ID>]
  let start: (ID) -> Void
  let stop: (ID) -> Void
  let restart: (ID) -> Void

  public init(
    sessions: [LocalModelSessionItem<ID>], start: @escaping (ID) -> Void,
    stop: @escaping (ID) -> Void, restart: @escaping (ID) -> Void
  ) {
    self.sessions = sessions
    self.start = start
    self.stop = stop
    self.restart = restart
  }

  public var body: some View {
    List(sessions) { session in
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 3) {
          Text(session.modelName)
            .font(.headline)
          Text(session.scope)
            .foregroundStyle(.secondary)
          Text(session.modelID)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 3) {
          Label(session.status, systemImage: session.isRunning ? "circle.fill" : "circle")
            .foregroundStyle(session.isRunning ? .green : .secondary)
          if let processID = session.processID {
            Text("PID \(processID)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if let error = session.errorMessage {
            Text(error)
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
              .help(error)
          }
        }
        .frame(width: 200, alignment: .leading)

        HStack(spacing: 8) {
          if session.isRunning {
            Button("Stop") { stop(session.id) }
            Button("Restart") { restart(session.id) }
              .disabled(session.isResponding)
          } else {
            Button("Start") { start(session.id) }
              .disabled(!session.canStart)
          }
        }
        .frame(width: 125, alignment: .trailing)
        .buttonStyle(FritzButtonStyle(.inline))
      }
      .padding(.vertical, 6)
    }
    .listStyle(.plain)
  }
}
