import AppKit
import Foundation

enum CSVExporter {
    static func export(assignment: Assignment) {
        let rubric = assignment.rubricItems.sorted(by: { $0.order < $1.order })
        let students = assignment.students.sorted(by: { $0.name < $1.name })

        var rows: [[String]] = []

        // Header
        var header = ["Student"]
        header += rubric.map { "\($0.name) (/\(formatPts($0.maxPoints)))" }
        header += ["Total", "Max", "Pct"]
        rows.append(header)

        // Data rows
        for student in students {
            var row = [student.name]
            var total = 0.0
            for item in rubric {
                if let score = student.scores.first(where: { $0.rubricItemID == item.id }) {
                    row.append(score.points.map { formatPts($0) } ?? "")
                    total += score.points ?? 0
                } else {
                    row.append("")
                }
            }
            let max = assignment.maxPoints
            let pct = max > 0 ? String(format: "%.1f%%", total / max * 100) : ""
            row += [formatPts(total), formatPts(max), pct]
            rows.append(row)
        }

        let csv = rows.map { row in
            row.map { cell in
                cell.contains(",") || cell.contains("\"") || cell.contains("\n")
                    ? "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : cell
            }.joined(separator: ",")
        }.joined(separator: "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(assignment.name) Scores.csv"

        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func formatPts(_ val: Double) -> String {
        val.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(val)) : String(format: "%.1f", val)
    }
}
