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

    // MARK: - D2L ID import

    /// Parse a D2L grade export CSV and populate orgDefinedId/username on matched students (by email).
    @discardableResult
    static func importD2LIds(assignment: Assignment, url: URL) -> (matched: Int, skipped: Int) {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return (0, 0) }
        let lines = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return (0, 0) }

        let header = parseCSVLine(lines[0]).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let idIdx    = header.firstIndex(of: "orgdefinedid"),
              let userIdx  = header.firstIndex(of: "username"),
              let emailIdx = header.firstIndex(of: "email") else { return (0, 0) }

        var matched = 0, skipped = 0
        for line in lines.dropFirst() {
            let cols = parseCSVLine(line)
            let maxIdx = max(idIdx, userIdx, emailIdx)
            guard cols.count > maxIdx else { continue }
            let rawId   = cols[idIdx].trimmingCharacters(in: .whitespaces)
            let rawUser = cols[userIdx].trimmingCharacters(in: .whitespaces)
            let email   = cols[emailIdx].trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty, !rawId.isEmpty else { continue }

            let orgId = rawId.hasPrefix("#") ? String(rawId.dropFirst()) : rawId
            let uname = rawUser.hasPrefix("#") ? String(rawUser.dropFirst()) : rawUser

            if let student = assignment.students.first(where: { $0.email.lowercased() == email.lowercased() }) {
                student.orgDefinedId = orgId
                student.username     = uname
                matched += 1
            } else {
                skipped += 1
            }
        }
        return (matched, skipped)
    }

    // MARK: - D2L grade export

    static func exportD2L(assignment: Assignment, columnHeader: String) {
        let students = assignment.students.sorted { $0.name < $1.name }

        var rows: [[String]] = []
        rows.append(["OrgDefinedId", "Username", "Last Name", "First Name", "Email", columnHeader, "End-of-Line Indicator"])

        for student in students {
            let (last, first) = splitName(student.name)
            let idStr   = student.orgDefinedId.isEmpty ? "" : "#\(student.orgDefinedId)"
            let userStr = student.username.isEmpty     ? "" : "#\(student.username)"
            rows.append([idStr, userStr, last, first, student.email, formatPts(student.totalScore), "#"])
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
        panel.nameFieldStringValue = "\(assignment.name) D2L Grades.csv"
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Helpers

    private static func splitName(_ name: String) -> (last: String, first: String) {
        let parts = name.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").filter { !$0.isEmpty }
        if parts.count <= 1 { return (name, "") }
        return (parts.last!, parts.dropLast().joined(separator: " "))
    }

    private static func parseCSVLine(_ line: String) -> [String] {
        var cols: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" { inQuotes.toggle() }
            else if ch == "," && !inQuotes { cols.append(current); current = "" }
            else { current.append(ch) }
        }
        cols.append(current)
        return cols
    }

    private static func formatPts(_ val: Double) -> String {
        val.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(val)) : String(format: "%.1f", val)
    }
}
