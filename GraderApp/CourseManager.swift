import AppKit
import SwiftData
import UniformTypeIdentifiers

@Observable
final class CourseManager {
    var bundleURL: URL?
    var modelContainer: ModelContainer?
    var isOpen: Bool { bundleURL != nil && modelContainer != nil }
    private(set) var recentURLs: [URL] = []

    private static let recentsKey = "GraderApp.recentCourses"
    private static let maxRecents = 10

    // Track whether we hold an active security scope that needs to be stopped on close
    private var securityScopedURL: URL?
    private var securityScopedAccessing = false

    init() {
        recentURLs = resolveBookmarks()
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
        closeCourse()

        // Start security scope (needed when URL comes from a stored bookmark;
        // returns false but is harmless for NSOpenPanel/file-association URLs)
        let accessing = url.startAccessingSecurityScopedResource()
        securityScopedURL = url
        securityScopedAccessing = accessing

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

        addToRecents(url)
    }

    // MARK: - Recents (security-scoped bookmarks for sandbox compatibility)

    private func addToRecents(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }

        var bookmarks = storedBookmarks()
        // Remove stale entry for same path
        bookmarks = bookmarks.filter { data in
            var stale = false
            let existing = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            return existing?.path != url.path
        }
        bookmarks.insert(bookmark, at: 0)
        if bookmarks.count > Self.maxRecents { bookmarks = Array(bookmarks.prefix(Self.maxRecents)) }
        UserDefaults.standard.set(bookmarks, forKey: Self.recentsKey)
        recentURLs = resolve(bookmarks)
    }

    private func resolveBookmarks() -> [URL] {
        resolve(storedBookmarks())
    }

    private func storedBookmarks() -> [Data] {
        (UserDefaults.standard.array(forKey: Self.recentsKey) as? [Data]) ?? []
    }

    private func resolve(_ bookmarks: [Data]) -> [URL] {
        bookmarks.compactMap { data in
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    func clearRecents() {
        UserDefaults.standard.removeObject(forKey: Self.recentsKey)
        recentURLs = []
    }

    func closeCourse() {
        if securityScopedAccessing {
            securityScopedURL?.stopAccessingSecurityScopedResource()
        }
        securityScopedURL = nil
        securityScopedAccessing = false
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
