import SwiftUI
import SwiftData

struct AssignmentSidebarView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Assignment.createdAt) private var assignments: [Assignment]
    @Query(sort: \RosterEntry.lastName) private var roster: [RosterEntry]

    @Binding var selectedAssignment: Assignment?
    @Binding var selectedStudent: Student?

    @State private var showingNewAssignment = false
    @State private var showingRubricEditor = false
    @State private var showingImporter = false
    @State private var showingRoster = false
    @State private var collapsedIDs: Set<UUID> = []

    var body: some View {
        List(selection: $selectedStudent) {
            ForEach(assignments) { assignment in
                AssignmentSection(
                    assignment: assignment,
                    isExpanded: Binding(
                        get: { !collapsedIDs.contains(assignment.id) },
                        set: { if $0 { collapsedIDs.remove(assignment.id) } else { collapsedIDs.insert(assignment.id) } }
                    ),
                    onRemoveStudent: { removeStudent($0, from: assignment) },
                    onEditRubric:   { selectedAssignment = assignment; showingRubricEditor = true },
                    onImport:       { selectedAssignment = assignment; showingImporter = true },
                    onExport:       { PDFExporter.showExportPanel(for: assignment) },
                    onDelete:       { deleteAssignment(assignment) }
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Grader")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                Button { showingNewAssignment = true } label: {
                    Label("New Assignment", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Divider().frame(height: 20)
                Button { showingRoster = true } label: {
                    Label("Roster", systemImage: "person.3")
                        .labelStyle(.iconOnly)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .help("Edit class roster")
            }
            .background(.bar)
        }
        .onChange(of: selectedStudent) { _, student in
            if let student {
                selectedAssignment = assignments.first { $0.students.contains(student) }
            }
        }
        .sheet(isPresented: $showingNewAssignment) {
            NewAssignmentSheet(isPresented: $showingNewAssignment)
        }
        .sheet(isPresented: $showingRubricEditor) {
            if let assignment = selectedAssignment {
                RubricEditorView(assignment: assignment, isPresented: $showingRubricEditor)
            }
        }
        .sheet(isPresented: $showingImporter) {
            if let assignment = selectedAssignment {
                ImporterView(assignment: assignment, isPresented: $showingImporter, roster: roster)
            }
        }
        .sheet(isPresented: $showingRoster) {
            RosterView(isPresented: $showingRoster)
        }
    }

    private func removeStudent(_ student: Student, from assignment: Assignment) {
        assignment.students.removeAll { $0.id == student.id }
        context.delete(student)
        if selectedStudent?.id == student.id { selectedStudent = nil }
    }

    private func deleteAssignment(_ assignment: Assignment) {
        if selectedAssignment?.id == assignment.id {
            selectedAssignment = nil
            selectedStudent = nil
        }
        context.delete(assignment)
    }
}

// Separate struct so the compiler doesn't time out on the nested Section+ForEach
private struct AssignmentSection: View {
    let assignment: Assignment
    @Binding var isExpanded: Bool
    let onRemoveStudent: (Student) -> Void
    let onEditRubric: () -> Void
    let onImport: () -> Void
    let onExport: () -> Void
    let onDelete: () -> Void

    private var sortedStudents: [Student] {
        assignment.students.sorted { $0.name < $1.name }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(sortedStudents) { student in
                StudentRow(student: student, rubricItems: assignment.rubricItems)
                    .tag(student)
                    .contextMenu {
                        Button("Remove Student", role: .destructive) {
                            onRemoveStudent(student)
                        }
                    }
            }
        } label: {
            HStack {
                Text(assignment.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Menu {
                    Button("Edit Rubric…", action: onEditRubric)
                    Button("Import PDFs…", action: onImport)
                    Button("Export Graded PDFs…", action: onExport)
                    Divider()
                    Button("Delete Assignment", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                // Prevent menu tap from toggling disclosure
                .onTapGesture {}
            }
        }
    }
}

struct StudentRow: View {
    let student: Student
    let rubricItems: [RubricItem]

    private var gradedCount: Int { student.scores.filter { $0.points != nil }.count }
    private var totalItems: Int { rubricItems.count }
    private var isComplete: Bool { gradedCount == totalItems && totalItems > 0 }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(student.name).font(.body)
                if totalItems > 0 {
                    let maxPts = rubricItems.reduce(0.0) { $0 + $1.maxPoints }
                    Text("\(student.totalScore, specifier: "%.1f") / \(maxPts, specifier: "%.0f") pts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isComplete {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else if gradedCount > 0 {
                Text("\(gradedCount)/\(totalItems)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }
}

struct NewAssignmentSheet: View {
    @Environment(\.modelContext) private var context
    @Binding var isPresented: Bool
    @State private var name = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("New Assignment").font(.headline)
            TextField("Assignment name (e.g. HW1, Midterm)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    guard !name.isEmpty else { return }
                    context.insert(Assignment(name: name))
                    isPresented = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
