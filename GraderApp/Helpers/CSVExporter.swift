import AppKit
import Foundation

enum CSVExporter {
    /// Full grade breakdown: identity columns, one column per rubric item, then the totals.
    /// Not a D2L import file — D2L only accepts columns matching existing grade items.
    static func exportGrades(assignment: Assignment, roster: [RosterEntry]) {
        let rubric = assignment.rubricItems.sorted { $0.order < $1.order }
        let students = assignment.students.sorted { $0.name < $1.name }
        let maxPoints = assignment.maxPoints

        var rows: [[String]] = []

        var header = ["OrgDefinedId", "Username", "Last Name", "First Name", "Email"]
        header += rubric.map(\.name)
        header += ["Total", "Max", "Pct"]
        rows.append(header)

        for student in students {
            let entry = roster.first { $0.email.lowercased() == student.email.lowercased() }
            let orgId = entry?.orgDefinedId ?? student.orgDefinedId
            let uname = entry?.username     ?? student.username
            let (last, first) = splitName(student.name)
            var row = [orgId, uname, last, first, student.email]

            var total = 0.0
            for item in rubric {
                // Ungraded stays blank rather than 0, so it reads differently from a real zero.
                let pts = student.scores.first { $0.rubricItemID == item.id }?.points
                row.append(pts.map { formatPts($0) } ?? "")
                total += pts ?? 0
            }

            let pct = maxPoints > 0 ? String(format: "%.1f%%", total / maxPoints * 100) : ""
            row += [formatPts(total), formatPts(maxPoints), pct]
            rows.append(row)
        }

        save(rows: rows, suggestedName: "\(assignment.name) Grades.csv")
    }

    // MARK: - D2L ID import

    /// Parse a D2L grade export CSV and populate orgDefinedId/username on matching roster entries (by email).
    @discardableResult
    static func importD2LIds(into roster: [RosterEntry], from url: URL) -> (matched: Int, skipped: Int) {
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

            if let entry = roster.first(where: { $0.email.lowercased() == email.lowercased() }) {
                entry.orgDefinedId = orgId
                entry.username     = uname
                matched += 1
            } else {
                skipped += 1
            }
        }
        return (matched, skipped)
    }

    // MARK: - D2L grade export

    /// Total score only. D2L rejects the file when unrecognized per-problem columns are
    /// present, so problem breakdowns live in `exportGrades` instead.
    static func exportD2L(assignment: Assignment, roster: [RosterEntry], columnHeader: String) {
        let students = assignment.students.sorted { $0.name < $1.name }

        var rows: [[String]] = []
        rows.append(["OrgDefinedId", "Username", "Last Name", "First Name", "Email", columnHeader, "End-of-Line Indicator"])

        for student in students {
            // Look up D2L identity from roster by email; fall back to fields stored on student
            let entry = roster.first { $0.email.lowercased() == student.email.lowercased() }
            let orgId = entry?.orgDefinedId ?? student.orgDefinedId
            let uname = entry?.username     ?? student.username
            let (last, first) = splitName(student.name)
            let idStr   = orgId.isEmpty ? "" : "#\(orgId)"
            let userStr = uname.isEmpty ? "" : "#\(uname)"
            rows.append([idStr, userStr, last, first, student.email, formatPts(student.totalScore), "#"])
        }

        save(rows: rows, suggestedName: "\(assignment.name) D2L Grades.csv")
    }

    // MARK: - Helpers

    private static func save(rows: [[String]], suggestedName: String) {
        let csv = rows.map { row in
            row.map { cell in
                cell.contains(",") || cell.contains("\"") || cell.contains("\n")
                    ? "\"\(cell.replacingOccurrences(of: "\"", with: "\"\""))\""
                    : cell
            }.joined(separator: ",")
        }.joined(separator: "\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        if panel.runModal() == .OK, let url = panel.url {
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

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
