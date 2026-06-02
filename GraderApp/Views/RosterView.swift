import SwiftUI
import SwiftData
import AppKit

struct RosterView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RosterEntry.lastName) private var roster: [RosterEntry]
    @Binding var isPresented: Bool

    @State private var firstName = ""
    @State private var lastName = ""
    @State private var email = ""
    @State private var editingEntry: RosterEntry?
    @State private var showingCSVImport = false
    @State private var csvError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Class Roster")
                    .font(.headline)
                Spacer()
                Button("Link D2L IDs…") { importD2LIds() }
                    .controlSize(.small)
                    .help("Import OrgDefinedId and Username from a D2L grade export CSV")
                Button("Import CSV…") { importCSV() }
                    .controlSize(.small)
            }
            .padding()

            Divider()

            if roster.isEmpty {
                ContentUnavailableView(
                    "No Students",
                    systemImage: "person.3",
                    description: Text("Add students manually or import a CSV with columns: First Name, Last Name, Email")
                )
                .frame(height: 160)
            } else {
                Table(roster) {
                    TableColumn("Last Name", value: \.lastName)
                    TableColumn("First Name", value: \.firstName)
                    TableColumn("Email", value: \.email)
                }
                .frame(minHeight: 180)
                .contextMenu(forSelectionType: RosterEntry.ID.self) { ids in
                    Button("Delete", role: .destructive) {
                        for entry in roster.filter({ ids.contains($0.id) }) {
                            context.delete(entry)
                        }
                    }
                }
            }

            Divider()

            // Add / edit row
            VStack(alignment: .leading, spacing: 8) {
                Text(editingEntry == nil ? "Add Student" : "Edit Student")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    TextField("First name", text: $firstName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Last name", text: $lastName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                    Button(editingEntry == nil ? "Add" : "Save") { commit() }
                        .buttonStyle(.borderedProminent)
                        .disabled(firstName.isEmpty || lastName.isEmpty)
                    if editingEntry != nil {
                        Button("Cancel") { clearForm() }
                    }
                }
            }
            .padding()

            if let err = csvError {
                Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal)
            }

            Divider()

            HStack {
                Text("\(roster.count) student\(roster.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 620, height: 480)
    }

    private func commit() {
        if let entry = editingEntry {
            entry.firstName = firstName
            entry.lastName = lastName
            entry.email = email
            editingEntry = nil
        } else {
            context.insert(RosterEntry(firstName: firstName, lastName: lastName, email: email))
        }
        clearForm()
    }

    private func clearForm() {
        firstName = ""; lastName = ""; email = ""; editingEntry = nil
    }

    private func importD2LIds() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Select a D2L grade export CSV to link OrgDefinedId and Username to roster entries by email"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = CSVExporter.importD2LIds(into: roster, from: url)
        let alert = NSAlert()
        alert.messageText = "D2L IDs Linked"
        alert.informativeText = "Matched \(result.matched) of \(result.matched + result.skipped) students by email."
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.message = "Select a CSV file with columns: First Name, Last Name, Email (header row optional)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let raw = try String(contentsOf: url, encoding: .utf8)
            let lines = raw.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            var added = 0
            for line in lines {
                let cols = parseCSVLine(line)
                guard cols.count >= 3 else { continue }
                let first = cols[0].trimmingCharacters(in: .whitespaces)
                let last  = cols[1].trimmingCharacters(in: .whitespaces)
                let mail  = cols[2].trimmingCharacters(in: .whitespaces)
                // Skip header row
                if first.lowercased() == "first" || first.lowercased() == "first name" { continue }
                guard !first.isEmpty, !last.isEmpty else { continue }
                context.insert(RosterEntry(firstName: first, lastName: last, email: mail))
                added += 1
            }
            csvError = added > 0 ? nil : "No valid rows found. Expected: First Name, Last Name, Email"
        } catch {
            csvError = "Could not read file: \(error.localizedDescription)"
        }
    }

    private func parseCSVLine(_ line: String) -> [String] {
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
}
