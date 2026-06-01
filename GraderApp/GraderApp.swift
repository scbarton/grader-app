import SwiftUI
import SwiftData

@main
struct GraderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1100, minHeight: 700)
        }
        .modelContainer(for: [Assignment.self, RosterEntry.self])
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Scores as CSV…") {
                    NotificationCenter.default.post(name: .exportCSV, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

extension Notification.Name {
    static let exportCSV = Notification.Name("exportCSV")
}
