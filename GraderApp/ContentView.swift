import SwiftUI
import SwiftData

struct ContentView: View {
    let bundleURL: URL
    let courseManager: CourseManager

    @Environment(\.modelContext) private var context
    @Query(sort: \Assignment.createdAt) private var assignments: [Assignment]

    @State private var selectedAssignment: Assignment?
    @State private var selectedStudent: Student?
    @State private var annotationTool: AnnotationTool = .pointer
    @State private var targetedRubricItem: RubricItem?

    var body: some View {
        NavigationSplitView {
            AssignmentSidebarView(
                bundleURL: bundleURL,
                courseManager: courseManager,
                selectedAssignment: $selectedAssignment,
                selectedStudent: $selectedStudent
            )
        } detail: {
            if let student = selectedStudent, let assignment = selectedAssignment {
                HStack(spacing: 0) {
                    PDFViewerView(student: student, assignment: assignment, bundleURL: bundleURL, tool: $annotationTool, targetedRubricItem: targetedRubricItem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScorePanelView(student: student, assignment: assignment, targetedRubricItem: $targetedRubricItem)
                        .frame(minWidth: 280, maxWidth: 280, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar {
                    AnnotationToolbar(tool: $annotationTool)
                }
            } else {
                ContentUnavailableView(
                    "Select a Student",
                    systemImage: "doc.text",
                    description: Text("Choose an assignment and student from the sidebar")
                )
            }
        }
        .onChange(of: selectedAssignment) { _, assignment in
            // Auto-target first rubric item when switching assignments
            let sorted = assignment?.rubricItems.sorted { $0.order < $1.order } ?? []
            if !sorted.contains(where: { $0.id == targetedRubricItem?.id }) {
                targetedRubricItem = sorted.first
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportCSV)) { _ in
            if let assignment = selectedAssignment {
                PDFExporter.showExportPanel(for: assignment, bundleURL: bundleURL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateStudent)) { note in
            guard let delta = note.object as? Int,
                  let assignment = selectedAssignment else { return }
            let students = assignment.students.sorted { $0.name < $1.name }
            guard !students.isEmpty else { return }
            if let current = selectedStudent,
               let idx = students.firstIndex(where: { $0.id == current.id }) {
                let newIdx = idx + delta
                if newIdx >= 0, newIdx < students.count {
                    selectedStudent = students[newIdx]
                }
            } else {
                selectedStudent = students.first
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Close Course", systemImage: "xmark.circle") {
                    courseManager.closeCourse()
                }
                .help("Close this course and return to the picker")
            }
        }
    }
}
