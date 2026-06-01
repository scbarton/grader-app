import AppKit
import PDFKit
import Foundation

enum PDFExporter {

    static func showExportPanel(for assignment: Assignment) {
        let panel = NSOpenPanel()
        panel.message = "Choose a destination folder for the graded PDFs"
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let rubric = assignment.rubricItems.sorted { $0.order < $1.order }
        var exported = 0
        var failed: [String] = []

        for student in assignment.students.sorted(by: { $0.name < $1.name }) {
            guard let bookmark = student.pdfBookmark,
                  let sourceURL = BookmarkHelper.resolve(bookmark),
                  let document = PDFDocument(url: sourceURL) else {
                failed.append(student.name)
                continue
            }

            if !rubric.isEmpty {
                if let page = makeRubricPage(student: student, rubric: rubric, assignmentName: assignment.name) {
                    document.insert(page, at: document.pageCount)
                }
            }

            let dest = folder.appendingPathComponent(student.fileName)
            if document.write(to: dest) { exported += 1 } else { failed.append(student.name) }
        }

        let alert = NSAlert()
        alert.messageText = failed.isEmpty ? "Export Complete" : "Export Finished with Errors"
        alert.alertStyle = failed.isEmpty ? .informational : .warning
        let destName = folder.lastPathComponent
        if failed.isEmpty {
            alert.informativeText = "Exported \(exported) PDF\(exported == 1 ? "" : "s") to \"\(destName)/\"."
        } else {
            alert.informativeText = "Exported \(exported) PDFs to \"\(destName)/\". Could not export: \(failed.joined(separator: ", "))."
        }
        alert.runModal()
    }

    // MARK: - Rubric page generation

    private static func makeRubricPage(student: Student, rubric: [RubricItem], assignmentName: String) -> PDFPage? {
        var pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else { return nil }

        ctx.beginPage(mediaBox: &pageRect)

        // Flip to top-down coordinates
        ctx.translateBy(x: 0, y: 792)
        ctx.scaleBy(x: 1, y: -1)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        drawRubric(student: student, rubric: rubric, assignmentName: assignmentName)
        NSGraphicsContext.restoreGraphicsState()

        ctx.endPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    private static func drawRubric(student: Student, rubric: [RubricItem], assignmentName: String) {
        let margin: CGFloat = 54
        let pageW: CGFloat = 612
        var y: CGFloat = 48

        // Column x positions
        let cProblem:  CGFloat = margin
        let cEarned:   CGFloat = margin + 300
        let cMax:      CGFloat = margin + 360
        let cComment:  CGFloat = margin + 410

        func attr(_ text: String, bold: Bool = false, size: CGFloat = 11, color: NSColor = .black) -> NSAttributedString {
            let font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        }

        func hline(_ yPos: CGFloat, alpha: CGFloat = 0.25) {
            NSColor.black.withAlphaComponent(alpha).setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: margin, y: yPos))
            p.line(to: NSPoint(x: pageW - margin, y: yPos))
            p.lineWidth = 0.5
            p.stroke()
        }

        // ── Title ──
        attr("GRADE SHEET", bold: true, size: 20).draw(at: NSPoint(x: margin, y: y))
        y += 30
        hline(y, alpha: 0.6)
        y += 10

        // ── Header info ──
        attr("Assignment: \(assignmentName)", bold: true, size: 12).draw(at: NSPoint(x: margin, y: y))
        y += 18
        attr("Student: \(student.name)", bold: true).draw(at: NSPoint(x: margin, y: y))
        if !student.email.isEmpty {
            let emailAttr = attr(student.email, color: .secondaryLabelColor)
            let emailW = emailAttr.size().width
            emailAttr.draw(at: NSPoint(x: pageW - margin - emailW, y: y))
        }
        y += 22
        hline(y, alpha: 0.6)
        y += 12

        // ── Column headers ──
        attr("Problem",  bold: true).draw(at: NSPoint(x: cProblem,  y: y))
        attr("Earned",   bold: true).draw(at: NSPoint(x: cEarned,   y: y))
        attr("Max",      bold: true).draw(at: NSPoint(x: cMax,      y: y))
        attr("Comment",  bold: true).draw(at: NSPoint(x: cComment,  y: y))
        y += 16
        hline(y)
        y += 10

        // ── Rubric rows ──
        var totalEarned = 0.0
        var totalMax    = 0.0
        var allGraded   = true

        for item in rubric {
            let score  = student.scores.first { $0.rubricItemID == item.id }
            let earned = score?.points
            let earnedText = earned.map { fmt($0) } ?? "—"
            if earned == nil { allGraded = false }

            attr(item.name).draw(at: NSPoint(x: cProblem, y: y))
            attr(earnedText, bold: earned != nil).draw(at: NSPoint(x: cEarned, y: y))
            attr(fmt(item.maxPoints)).draw(at: NSPoint(x: cMax, y: y))

            if let comment = score?.comment, !comment.isEmpty {
                let truncated = comment.count > 55 ? String(comment.prefix(52)) + "…" : comment
                attr(truncated, size: 10, color: .secondaryLabelColor).draw(at: NSPoint(x: cComment, y: y))
            }

            totalEarned += earned ?? 0
            totalMax    += item.maxPoints
            y += 18
        }

        y += 4
        hline(y, alpha: 0.6)
        y += 10

        // ── Total row ──
        attr("Total", bold: true, size: 12).draw(at: NSPoint(x: cProblem, y: y))
        attr(fmt(totalEarned), bold: true, size: 12).draw(at: NSPoint(x: cEarned, y: y))
        attr(fmt(totalMax),    bold: true, size: 12).draw(at: NSPoint(x: cMax,    y: y))
        if totalMax > 0 {
            let pct = String(format: "%.1f%%", totalEarned / totalMax * 100)
            let status = allGraded ? "" : " (incomplete)"
            attr(pct + status, bold: true, size: 12).draw(at: NSPoint(x: cComment, y: y))
        }
        y += 20
        hline(y, alpha: 0.6)
    }

    private static func fmt(_ val: Double) -> String {
        val.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(val)) : String(format: "%.1f", val)
    }
}
