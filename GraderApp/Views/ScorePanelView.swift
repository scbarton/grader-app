import SwiftUI

struct ScorePanelView: View {
    @Bindable var student: Student
    let assignment: Assignment
    @Binding var targetedRubricItem: RubricItem?

    private var sortedRubric: [RubricItem] {
        assignment.rubricItems.sorted(by: { $0.order < $1.order })
    }

    private func score(for item: RubricItem) -> Score? {
        student.scores.first { $0.rubricItemID == item.id }
    }

    private func ensureScore(for item: RubricItem) -> Score {
        if let existing = score(for: item) { return existing }
        let s = Score(rubricItemID: item.id)
        student.scores.append(s)
        return s
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(student.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            if sortedRubric.isEmpty {
                ContentUnavailableView(
                    "No Rubric",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Add problems in the rubric editor")
                )
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(sortedRubric) { item in
                            ScoreRow(
                                item: item,
                                score: ensureScore(for: item),
                                isTargeted: targetedRubricItem?.id == item.id,
                                onTarget: { targetedRubricItem = item }
                            )
                            Divider()
                        }
                    }
                }

                Divider()

                // Total
                HStack {
                    Text("Total")
                        .font(.headline)
                    Spacer()
                    let total = student.totalScore
                    let max = assignment.maxPoints
                    Text("\(total, specifier: "%.1f") / \(max, specifier: "%.0f")")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(scoreColor(total: total, max: max))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    private func scoreColor(total: Double, max: Double) -> Color {
        guard max > 0 else { return .primary }
        let pct = total / max
        if pct >= 0.9 { return .green }
        if pct >= 0.7 { return .primary }
        return .red
    }
}

struct ScoreRow: View {
    let item: RubricItem
    @Bindable var score: Score
    var isTargeted: Bool = false
    var onTarget: () -> Void = {}

    @State private var pointsText: String = ""
    @FocusState private var isPointsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Button(action: onTarget) {
                    Text(isTargeted ? "🎯" : "◎")
                        .font(.system(size: isTargeted ? 15 : 13))
                        .opacity(isTargeted ? 1 : 0.35)
                }
                .buttonStyle(.borderless)
                .help(isTargeted ? "Targeted — click PDF in grade mode to stamp" : "Target this problem")
                Text(item.name)
                    .font(.subheadline)
                    .fontWeight(isTargeted ? .bold : .medium)
                    .foregroundStyle(isTargeted ? Color.accentColor : .primary)
                Spacer()
                HStack(spacing: 4) {
                    TextField("—", text: $pointsText)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .focused($isPointsFocused)
                        .onAppear { pointsText = score.points.map { formatPts($0) } ?? "" }
                        .onChange(of: score.points) { _, val in
                            if !isPointsFocused {
                                pointsText = val.map { formatPts($0) } ?? ""
                            }
                        }
                        .onChange(of: isPointsFocused) { _, focused in
                            if !focused { commitPoints() }
                        }
                        .onSubmit { commitPoints() }
                    Text("/ \(item.maxPoints, specifier: "%.0f")")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            // Quick-set buttons — horizontal scroll so they never overflow the panel
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(quickValues(for: item.maxPoints), id: \.self) { val in
                        Button(formatPts(val)) {
                            score.points = val
                            pointsText = formatPts(val)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundStyle(score.points == val ? .white : .primary)
                        .background(score.points == val ? Color.accentColor : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    if score.points != nil {
                        Button(action: clearScore) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                        .foregroundStyle(.secondary)
                    }
                }
            }

}
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private func commitPoints() {
        let clean = pointsText.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty {
            score.points = nil
        } else if let val = Double(clean) {
            let clamped = min(max(0, val), item.maxPoints)
            score.points = clamped
            pointsText = formatPts(clamped)
        } else {
            pointsText = score.points.map { formatPts($0) } ?? ""
        }
    }

    private func clearScore() {
        score.points = nil
        pointsText = ""
    }

    private func quickValues(for max: Double) -> [Double] {
        if max <= 5 {
            return stride(from: 0, through: max, by: 1).map { $0 }
        } else if max <= 10 {
            return [0, max * 0.5, max * 0.75, max * 0.9, max]
        } else {
            return [0, max * 0.5, max * 0.75, max * 0.9, max]
        }
    }

    private func formatPts(_ val: Double) -> String {
        val.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(val)) : String(format: "%.1f", val)
    }
}
