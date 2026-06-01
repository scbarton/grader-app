import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Assignment.createdAt) private var assignments: [Assignment]

    @State private var selectedAssignment: Assignment?
    @State private var selectedStudent: Student?
    @State private var annotationTool: AnnotationTool = .pointer

    var body: some View {
        NavigationSplitView {
            AssignmentSidebarView(
                selectedAssignment: $selectedAssignment,
                selectedStudent: $selectedStudent
            )
        } detail: {
            if let student = selectedStudent, let assignment = selectedAssignment {
                HSplitView {
                    PDFViewerView(student: student, tool: $annotationTool)
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                    ScorePanelView(student: student, assignment: assignment)
                        .frame(minWidth: 240, maxWidth: 340, maxHeight: .infinity)
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
        .onReceive(NotificationCenter.default.publisher(for: .exportCSV)) { _ in
            if let assignment = selectedAssignment {
                CSVExporter.export(assignment: assignment)
            }
        }
    }
}
