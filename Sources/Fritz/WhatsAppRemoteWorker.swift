import Foundation
import Observation

public protocol WhatsAppRemoteClient: Sendable {
  func whatsAppConnection() async throws -> WhatsAppConnection
  func claimWhatsAppCommand() async throws -> WhatsAppRemoteClaim
  func replyToWhatsAppCommand(id: String, epoch: String, text: String) async throws
}

extension IntegrationClient: WhatsAppRemoteClient {}

/// App-owned polling and execution. A settings epoch invalidates both queued work and replies.
@MainActor
@Observable
public final class WhatsAppRemoteWorker {
  public private(set) var errorMessage: String?
  @ObservationIgnored private var poll: Task<Void, Never>?
  @ObservationIgnored private var execution: Task<Void, Never>?
  private let invalidate: @MainActor () -> Void
  private let formatReply: @MainActor (String) -> String
  private var epoch: String?
  private var generation = UUID()
  private var executionID = UUID()
  private let client: any WhatsAppRemoteClient
  private let waitForPoll: @Sendable () async throws -> Void

  public init(
    client: any WhatsAppRemoteClient, invalidate: @escaping @MainActor () -> Void,
    formatReply: @escaping @MainActor (String) -> String,
    waitForPoll: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(2))
    }
  ) {
    self.invalidate = invalidate
    self.formatReply = formatReply
    self.client = client
    self.waitForPoll = waitForPoll
  }

  deinit {
    poll?.cancel()
    execution?.cancel()
  }

  public func stop() {
    generation = UUID()
    poll?.cancel()
    poll = nil
    execution?.cancel()
    execution = nil
    invalidate()
    epoch = nil
  }

  public func start(execute: @escaping @MainActor (String) async throws -> String) {
    stop()
    let generation = generation
    poll = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.generation == generation else { return }
        do {
          let connection = try await client.whatsAppConnection()
          try Task.checkCancellation()
          if epoch != connection.remoteEpoch || !connection.enabled
            || connection.remoteEnabled != true || !connection.isConnected
          {
            execution?.cancel()
            execution = nil
            invalidate()
            epoch = connection.remoteEpoch
          }
          if connection.enabled, connection.remoteEnabled == true, connection.isConnected,
            execution == nil
          {
            let claim = try await client.claimWhatsAppCommand()
            try Task.checkCancellation()
            guard claim.epoch == epoch else { continue }
            if let command = claim.command {
              let commandEpoch = claim.epoch
              let executionID = UUID()
              self.executionID = executionID
              execution = Task { [weak self] in
                guard let self else { return }
                defer {
                  if self.generation == generation, self.epoch == commandEpoch,
                    self.executionID == executionID
                  {
                    self.execution = nil
                  }
                }
                let response: String
                do {
                  try Task.checkCancellation()
                  response = try await execute(command.text)
                } catch is CancellationError { return } catch {
                  response = "Could not complete the command: \(error.localizedDescription)"
                }
                guard !Task.isCancelled, self.generation == generation, self.epoch == commandEpoch
                else { return }
                do {
                  try await client.replyToWhatsAppCommand(
                    id: command.id, epoch: commandEpoch,
                    text: formatReply(response))
                } catch {
                  guard !Task.isCancelled, self.generation == generation else { return }
                  self.errorMessage = error.localizedDescription
                }
              }
            }
          }
        } catch is CancellationError { return } catch {
          guard !Task.isCancelled, self.generation == generation else { return }
          errorMessage = error.localizedDescription
          // Loss of the authorization/status channel cancels work, never retries commands.
          execution?.cancel()
          execution = nil
          invalidate()
        }
        do { try await waitForPoll() } catch { return }
      }
    }
  }

}
