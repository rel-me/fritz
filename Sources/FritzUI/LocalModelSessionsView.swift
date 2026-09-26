import SwiftUI

/// Local-model management content, including the empty state and native process list.
public struct LocalModelSessionsView<ID: Hashable>: View {
  let sessions: [LocalModelSessionItem<ID>]
  let start: (ID) -> Void
  let stop: (ID) -> Void
  let restart: (ID) -> Void
  let emptyDescription: String
  let listBackground: Color
  let download: () -> Void

  public init(
    sessions: [LocalModelSessionItem<ID>], start: @escaping (ID) -> Void,
    stop: @escaping (ID) -> Void, restart: @escaping (ID) -> Void,
    emptyDescription: String, listBackground: Color, download: @escaping () -> Void
  ) {
    self.sessions = sessions
    self.start = start
    self.stop = stop
    self.restart = restart
    self.emptyDescription = emptyDescription
    self.listBackground = listBackground
    self.download = download
  }

  public var body: some View {
    if sessions.isEmpty {
      ContentUnavailableView {
        Label("No Local Model Sessions", systemImage: "cpu")
      } description: {
        Text(emptyDescription)
      } actions: {
        Button("Download Models", action: download)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      LocalModelSessionsList(sessions: sessions, start: start, stop: stop, restart: restart)
        .fritzButtonSize(.regular)
        .scrollContentBackground(.hidden)
        .alternatingRowBackgrounds(.disabled)
        .background(listBackground)
    }
  }
}
