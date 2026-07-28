import SwiftUI
import AppKit

/// Settings pane (App menu → Settings…, ⌘,) for rebinding the annotation-tool keys.
/// Each row shows the action and a button that records the next keypress. Bindings are
/// single letters; digits/duplicates are rejected with an inline message.
struct ShortcutSettingsView: View {
    @State private var settings = ShortcutSettings.shared
    @State private var listening: ShortcutAction?
    @State private var monitor: Any?
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                ForEach(ShortcutAction.allCases) { action in
                    GridRow {
                        HStack(spacing: 6) {
                            if let symbol = action.symbol { Text(symbol) }
                            Text(action.title)
                        }
                        .gridColumnAlignment(.leading)

                        Button {
                            toggleListening(action)
                        } label: {
                            Text(listening == action ? "Press a key…" : settings.key(for: action).uppercased())
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 90)
                        }
                        .buttonStyle(.bordered)
                        .tint(listening == action ? .accentColor : nil)
                    }
                }
            }
            .padding(.bottom, 8)

            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            } else {
                Text("Press a letter to rebind. Digits and Cmd+arrow navigation are fixed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }

            Divider()

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    stopListening()
                    warning = nil
                    settings.resetToDefaults()
                }
            }
            .padding(.top, 8)
        }
        .padding(20)
        .frame(width: 360)
        .onDisappear { stopListening() }
    }

    // MARK: - Key recording

    private func toggleListening(_ action: ShortcutAction) {
        if listening == action { stopListening(); return }
        warning = nil
        listening = action
        stopMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event, for: action)
            return nil  // consume while recording
        }
    }

    private func handle(_ event: NSEvent, for action: ShortcutAction) {
        if event.keyCode == 53 { stopListening(); return }  // Escape → cancel

        let raw = event.charactersIgnoringModifiers ?? ""
        guard let key = ShortcutSettings.normalize(raw) else {
            warning = "“\(raw)” isn’t a letter. Choose A–Z."
            stopListening()
            return
        }
        if let owner = settings.conflict(for: key, excluding: action) {
            warning = "“\(key.uppercased())” is already used by \(owner.title)."
            stopListening()
            return
        }
        settings.setKey(key, for: action)
        warning = nil
        stopListening()
    }

    private func stopListening() {
        listening = nil
        stopMonitor()
    }

    private func stopMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
