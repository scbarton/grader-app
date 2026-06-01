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
                HSplitView {
                    PDFViewerView(student: student, assignment: assignment, bundleURL: bundleURL, tool: $annotationTool, targetedRubricItem: targetedRubricItem)
                        .frame(minWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
                    ScorePanelView(student: student, assignment: assignment, tool: annotationTool, targetedRubricItem: $targetedRubricItem)
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
                PDFExporter.showExportPanel(for: assignment, bundleURL: bundleURL)
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
