import SwiftUI

struct AnnotationToolbar: ToolbarContent {
    @Binding var tool: AnnotationTool

    static let highlightNotification = Notification.Name("addHighlight")

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {

            ToolButton(label: "Select", icon: "arrow.up.left", active: tool == .pointer) {
                tool = .pointer
            }
            .help("Select annotation · click to highlight, then ⌫ or right-click to delete")

            ToolButton(label: "Delete", icon: "trash", active: tool == .delete) {
                tool = .delete
            }
            .help("Delete annotation · click any annotation to remove it · shortcut: D")

            ToolButton(label: "Grade", icon: "seal.fill", active: tool == .grade) {
                tool = .grade
            }
            .foregroundStyle(tool == .grade ? Color(nsColor: .white) : Color(red: 0, green: 0.4, blue: 0.12))
            .help("Place grade stamp · click where problem starts, choose problem · shortcut: G")

            ToolButton(label: "Comment", icon: "text.bubble", active: tool == .text) {
                tool = .text
            }
            .help("Add text comment · click anywhere on the PDF · shortcut: C")

            ToolButton(label: "Highlight", icon: "highlighter", active: tool == .highlight) {
                tool = .highlight
            }
            .help("Highlight text · select tool, drag to select text · shortcut: H")

            Divider()

            ForEach(AnnotationTool.StampType.allCases, id: \.self) { stampType in
                Button {
                    tool = .stamp(stampType)
                } label: {
                    Text(stampType.symbol)
                        .font(.system(size: 18))
                        .frame(width: 32, height: 22)
                }
                .background(tool == .stamp(stampType) ? Color.accentColor.opacity(0.15) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .help(stampType.label + " · select tool, then click on PDF")
            }
        }
    }
}

private struct ToolButton: View {
    let label: String
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 22)
        }
        .background(active ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
