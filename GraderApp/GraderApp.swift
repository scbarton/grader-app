import SwiftUI
import SwiftData

@main
struct GraderApp: App {
    @State private var courseManager = CourseManager()

    var body: some Scene {
        WindowGroup {
            Group {
                if courseManager.isOpen,
                   let container = courseManager.modelContainer,
                   let bundleURL = courseManager.bundleURL {
                    ContentView(bundleURL: bundleURL, courseManager: courseManager)
                        .modelContainer(container)
                } else {
                    CoursePicker(courseManager: courseManager)
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .onOpenURL { url in
                guard url.pathExtension == "gradercourse" else { return }
                do { try courseManager.open(url: url) }
                catch { NSAlert(error: error).runModal() }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Course…") { courseManager.newCourse() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open Course…") { courseManager.openExisting() }
                    .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    if courseManager.recentURLs.isEmpty {
                        Text("No Recent Courses")
                    } else {
                        ForEach(courseManager.recentURLs, id: \.path) { url in
                            Button(url.deletingPathExtension().lastPathComponent) {
                                do { try courseManager.open(url: url) }
                                catch { NSAlert(error: error).runModal() }
                            }
                        }
                        Divider()
                        Button("Clear Menu") { courseManager.clearRecents() }
                    }
                }
                if courseManager.isOpen {
                    Divider()
                    Button("Close Course") { courseManager.closeCourse() }
                }
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Scores as CSV…") {
                    NotificationCenter.default.post(name: .exportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("[", modifiers: .control)
            }
        }
    }
}

extension Notification.Name {
    static let exportCSV = Notification.Name("exportCSV")
}
