import SwiftUI
import SwiftData
import AppKit

struct ImporterView: View {
    @Bindable var assignment: Assignment
    @Binding var isPresented: Bool
    var roster: [RosterEntry] = []

    @Environment(\.modelContext) private var context

    @State private var pendingFiles: [PendingFile] = []
    @State private var errorMessage: String?
    @State private var isScaling = false

    var body: some View {
        VStack(spacing: 0) {
            Text("Import PDFs — \(assignment.name)")
                .font(.headline)
                .padding()

            Divider()

            if pendingFiles.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Drop PDF files here or click to browse")
                        .foregroundStyle(.secondary)
                    Button("Choose Files…") { browse() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach($pendingFiles) { $file in
                            PendingFileRow(file: $file, roster: roster) {
                                pendingFiles.removeAll { $0.id == file.id }
                            }
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 200)

                if let err = errorMessage {
                    Text(err).foregroundStyle(.red).font(.caption).padding(.horizontal)
                }
            }

            Divider()

            HStack {
                if !pendingFiles.isEmpty {
                    Button("Add More…") { browse() }
                    Spacer()
                    if roster.isEmpty {
                        Text("Tip: add a class roster to auto-match names")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") { isPresented = false }
                    Button("Import \(pendingFiles.count) Student\(pendingFiles.count == 1 ? "" : "s")") {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isScaling)
                } else {
                    Spacer()
                    Button("Cancel") { isPresented = false }
                }
            }
            .padding()

            if isScaling {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scaling pages to letter size…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            }
        }
        .frame(width: 560, height: 440)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK { addURLs(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                defer { group.leave() }
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.pathExtension.lowercased() == "pdf" else { return }
                urls.append(url)
            }
        }
        group.notify(queue: .main) { addURLs(urls) }
        return true
    }

    private func addURLs(_ urls: [URL]) {
        let existing = Set(assignment.students.map(\.fileName))
        for url in urls {
            guard !existing.contains(url.lastPathComponent) else { continue }
            let guessedName = nameFromFilename(url.deletingPathExtension().lastPathComponent)
            let matched = bestRosterMatch(for: guessedName)
            pendingFiles.append(PendingFile(
                url: url,
                name: matched?.fullName ?? guessedName,
                email: matched?.email ?? "",
                rosterEntry: matched
            ))
        }
    }

    private func performImport() {
        isScaling = true
        let files = pendingFiles
        // Capture UUIDs on the main thread — don't pass SwiftData objects across threads
        let rubricIDs = assignment.rubricItems.map(\.id)

        DispatchQueue.global(qos: .userInitiated).async {
            for file in files {
                PDFScaler.scaleToLetterIfNeeded(url: file.url)
            }

            DispatchQueue.main.async {
                for file in files {
                    guard let bookmark = BookmarkHelper.bookmark(for: file.url) else {
                        errorMessage = "Could not bookmark \(file.url.lastPathComponent) — check file permissions"
                        isScaling = false
                        return
                    }
                    let student = Student(name: file.name, email: file.email, fileName: file.url.lastPathComponent)
                    student.pdfBookmark = bookmark
                    for id in rubricIDs {
                        student.scores.append(Score(rubricItemID: id))
                    }
                    assignment.students.append(student)
                }
                isScaling = false
                isPresented = false
            }
        }
    }

    // MARK: - Name helpers

    private func nameFromFilename(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
           .replacingOccurrences(of: "-", with: " ")
           .trimmingCharacters(in: .whitespaces)
           .capitalized
    }

    private func bestRosterMatch(for name: String) -> RosterEntry? {
        guard !roster.isEmpty else { return nil }
        let tokens = name.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var best: (RosterEntry, Int)? = nil
        for entry in roster {
            let entryTokens = "\(entry.firstName) \(entry.lastName)".lowercased()
                .components(separatedBy: .whitespaces)
            let matches = tokens.filter { entryTokens.contains($0) }.count
            if matches > 0, matches > (best?.1 ?? 0) { best = (entry, matches) }
        }
        return best?.0
    }
}

// MARK: - Row view

struct PendingFileRow: View {
    @Binding var file: PendingFile
    let roster: [RosterEntry]
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.fill").foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 160, alignment: .leading)

            TextField("Name", text: $file.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)

            TextField("Email", text: $file.email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            if !roster.isEmpty {
                Picker("", selection: $file.rosterEntry) {
                    Text("—").tag(Optional<RosterEntry>.none)
                    ForEach(roster) { entry in
                        Text(entry.sortKey).tag(Optional(entry))
                    }
                }
                .frame(width: 130)
                .onChange(of: file.rosterEntry) { _, entry in
                    if let entry {
                        file.name = entry.fullName
                        file.email = entry.email
                    }
                }
            }

            Button(action: onRemove) {
                Image(systemName: "xmark").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Data model

struct PendingFile: Identifiable {
    let id = UUID()
    let url: URL
    var name: String
    var email: String
    var rosterEntry: RosterEntry?
}
