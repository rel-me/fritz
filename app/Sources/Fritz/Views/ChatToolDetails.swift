import SwiftUI

// REL's selectable code-block presentation, limited to Fritz's tool records.
struct ChatToolDetails: View {
    let activity: ChatToolActivity
    let isActive: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(activity.name).font(.headline)
                Text(activity.summary).foregroundStyle(.secondary).textSelection(.enabled)
                Text(activity.status(isActive: isActive).rawValue).font(.caption)
                Text("Arguments").font(.subheadline.weight(.semibold))
                ChatToolCodeBlock(text: activity.arguments)
                if let result = activity.result {
                    Text("Result").font(.subheadline.weight(.semibold))
                    ChatToolCodeBlock(text: result)
                }
            }
            .padding(16)
        }
        .frame(width: 480)
        .frame(maxHeight: 560)
    }
}

private struct ChatToolCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(text.isEmpty ? "<empty>" : text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(minHeight: 80, maxHeight: 320)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(.rect(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).stroke(.separator)
        }
    }
}

enum ChatActivityStatus: String {
    case running = "In progress"
    case completed = "Completed"
    case failed = "Failed"
    case interrupted = "Interrupted"
}

extension ChatToolActivity {
    func status(isActive: Bool) -> ChatActivityStatus {
        if let success { return success ? .completed : .failed }
        return isActive ? .running : .interrupted
    }
}

extension ChatMessage {
    var workSummary: String {
        guard let elapsedTime else { return "Work details" }
        // REL's compact elapsed-time format; old records have no invented duration.
        let totalSeconds = max(1, Int(elapsedTime.rounded()))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60
        let duration: String
        if hours > 0 {
            duration = minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        } else if minutes > 0 {
            duration = "\(minutes)m \(seconds)s"
        } else {
            duration = "\(seconds)s"
        }
        return isComplete ? "Worked for \(duration)" : "Stopped after \(duration)"
    }
}
