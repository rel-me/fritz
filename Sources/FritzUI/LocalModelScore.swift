import Fritz
import SwiftUI

enum LocalModelScoreFilter: Hashable {
    case all
    case scored
    case unscored
    case minimum(Int)

    func includes(_ points: Int?) -> Bool {
        switch self {
        case .all: true
        case .scored: points != nil
        case .unscored: points == nil
        case let .minimum(minimum): points.map { $0 >= minimum } ?? false
        }
    }
}

struct LocalModelScorePicker: View {
    @Binding var selection: LocalModelScoreFilter
    let catalog: [NativeModelDescriptor]

    var body: some View {
        Picker("Score", selection: $selection) {
            Text("All Scores").tag(LocalModelScoreFilter.all)
            Text("Scored Only").tag(LocalModelScoreFilter.scored)
            Text("Unscored Only").tag(LocalModelScoreFilter.unscored)
            ForEach(Array(Set(catalog.compactMap(\.benchmarkScore?.points))).sorted().dropFirst(), id: \.self) { minimum in
                Text("At Least \(minimum)").tag(LocalModelScoreFilter.minimum(minimum))
            }
        }
    }
}

struct LocalModelScoreCell: View {
    static let methodology = URL(string: "https://artificialanalysis.ai/methodology/intelligence-benchmarking")!
    let score: NativeModelDescriptor.BenchmarkScore?

    var body: some View {
        if let score {
            Text(score.points, format: .number)
                .monospacedDigit()
                .help("Artificial Analysis Intelligence Index v5.0.1 · \(score.configuration) · Published model score")
        } else {
            Text("—")
                .foregroundStyle(.secondary)
                .help("No comparable benchmark score published")
                .accessibilityLabel("Unscored")
        }
    }
}

struct LocalModelScoreComparator<Row>: SortComparator {
    let points: KeyPath<Row, Int?> & Sendable
    var order: SortOrder = .reverse

    func compare(_ lhs: Row, _ rhs: Row) -> ComparisonResult {
        switch (lhs[keyPath: points], rhs[keyPath: points]) {
        case let (left?, right?): ComparableComparator<Int>(order: order).compare(left, right)
        case (_?, nil): .orderedAscending
        case (nil, _?): .orderedDescending
        case (nil, nil): .orderedSame
        }
    }
}
