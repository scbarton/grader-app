import AppKit
import SwiftData
import UniformTypeIdentifiers

@Observable
final class CourseManager {
    var bundleURL: URL?
    var modelContainer: ModelContainer?
    var isOpen: Bool { bundleURL != nil && modelContainer != nil }
    private(set) var recentURLs: [URL] = []

    init() {
        recentURLs = NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension == "gradercourse" }
    }

    // MARK: - Create / Open

    func newCourse() {
        let panel = NSSavePanel()
        panel.message = "Choose a location for your new course"
        panel.nameFieldStringValue = "My Course"
        panel.allowedContentTypes = [.gradercourse]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return }

        var url = panel.url!
        if url.pathExtension.lowercased() != "gradercourse" {
            url = url.appendingPathExtension("gradercourse")
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try open(url: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func openExisting() {
        let panel = NSOpenPanel()
        panel.message = "Open a Grader course"
        panel.allowedContentTypes = [.gradercourse]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try open(url: url) } catch { NSAlert(error: error).runModal() }
    }

    func open(url: URL) throws {
        let storeURL = url.appendingPathComponent("course.sqlite")
        let config = ModelConfiguration(url: storeURL)
        let container = try ModelContainer(
            for: Assignment.self, RosterEntry.self,
            configurations: config
        )
        modelContainer = container
        bundleURL = url

        // Ensure PDFs directory exists
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("PDFs"),
            withIntermediateDirectories: true
        )

        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentURLs = NSDocumentController.shared.recentDocumentURLs
            .filter { $0.pathExtension == "gradercourse" }
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentURLs = []
    }

    func closeCourse() {
        modelContainer = nil
        bundleURL = nil
    }

    // MARK: - PDF path helpers

    /// Folder for a given assignment's PDFs inside the bundle.
    func pdfDirectory(for assignment: Assignment) -> URL? {
        guard let base = bundleURL else { return nil }
        let safe = assignment.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return base.appendingPathComponent("PDFs/\(safe)")
    }

    /// Full URL for a student's PDF.
    func pdfURL(for student: Student) -> URL? {
        guard let base = bundleURL, !student.pdfRelativePath.isEmpty else { return nil }
        return base.appendingPathComponent(student.pdfRelativePath)
    }

}
