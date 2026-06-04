# GraderApp

A native macOS app for annotating and grading student PDF submissions. Built with SwiftUI, PDFKit, and SwiftData.

## Features

**Course bundles** — all data for a course lives in a single `.gradercourse` package: student PDFs, rubric, scores, and roster. Open, copy, and back up a course by moving one file.

**Assignments and rubrics** — create assignments, define rubric problems with point values, and target a specific problem for stamping.

**PDF annotation tools:**

| Tool | Shortcut | Description |
|------|----------|-------------|
| Select | S | Click annotations to select; Delete or right-click to remove |
| Grade stamp | G | Click PDF to place a labeled score stamp for the targeted problem |
| Comment | C | Click to place a text comment; double-click to edit |
| Highlight | H | Drag to highlight text |
| ✅ / ❌ / 🆗 | V / X / K | Emoji stamps for correct, incorrect, and partial credit |
| Delete | D | Click any annotation to remove it |

**Score panel** — right sidebar shows the rubric for the current student. Enter scores by typing or clicking quick-value buttons. Total updates live with color coding (green ≥ 90%, red < 70%).

**Student navigation** — Cmd+Up / Cmd+Down moves between students. Cmd+[ / Cmd+] moves between rubric problems. On student switch, the PDF scrolls to the grade stamp for the targeted problem.

**D2L integration** — import D2L grade export CSV to populate the roster; export grades back to D2L-compatible CSV with matched column headers.

**Roster view** — manage students, link D2L usernames and org-defined IDs, and track which PDFs are assigned.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode 15+ to build from source

## Building

Open `GraderApp.xcodeproj` in Xcode and build the `GraderApp` scheme, or:

```bash
xcodebuild -project GraderApp.xcodeproj -scheme GraderApp -configuration Release build
```

## Workflow

1. **Create a course** — File → New Course, or open an existing `.gradercourse` bundle.
2. **Add an assignment** — click + in the left sidebar, enter a name, and configure rubric problems.
3. **Import students** — drag PDFs onto the assignment in the sidebar, or import a D2L grade CSV to auto-populate the roster and link student IDs.
4. **Grade** — select a student. Use G to enter grade mode, target a rubric problem in the right panel, and click the PDF to stamp the score. Use C to add comments, H to highlight, and the emoji stamps for quick marks.
5. **Export** — File → Export Grades to produce a CSV ready for D2L upload.

## File Format

A `.gradercourse` bundle is a macOS package directory:

```
CourseName.gradercourse/
├── default.store          # SwiftData SQLite database (assignments, rubric, scores, roster)
├── default.store-wal      # SQLite WAL journal
└── PDFs/
    └── AssignmentName/
        ├── student1.pdf   # annotated student PDF (annotations written directly to file)
        └── student2.pdf
```

Annotations are embedded in the PDF files themselves, so a graded PDF can be opened in any PDF viewer.

## Keyboard Shortcuts

| Action | Shortcut |
|--------|----------|
| Next student | Cmd+Down |
| Previous student | Cmd+Up |
| Next problem | Cmd+] |
| Previous problem | Cmd+[ |
| Focus PDF view | Cmd+Space |
| Select tool | S |
| Grade stamp | G |
| Comment | C |
| Highlight | H |
| Correct stamp | V |
| Incorrect stamp | X |
| Partial stamp | K |
| Delete tool | D |
| Export grades | Cmd+E |
| Toggle score panel | Cmd+Shift+P |
| Toggle left sidebar | Ctrl+[ |
