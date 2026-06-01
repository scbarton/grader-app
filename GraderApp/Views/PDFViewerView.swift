import SwiftUI
import PDFKit
import AppKit

// MARK: - Annotation tool model

enum AnnotationTool: Equatable, Hashable {
    case pointer
    case text
    case highlight
    case delete
    case grade
    case stamp(StampType)

    enum StampType: CaseIterable, Hashable {
        case correct, incorrect, partial

        var symbol: String {
            switch self {
            case .correct:   "✅"
            case .incorrect: "❌"
            case .partial:   "🆗"
            }
        }

        var color: NSColor {
            switch self {
            case .correct:   .systemGreen
            case .incorrect: .systemRed
            case .partial:   .systemBlue
            }
        }

        var label: String {
            switch self {
            case .correct:   "Correct (V)"
            case .incorrect: "Incorrect (X)"
            case .partial:   "OK / Partial (K)"
            }
        }
    }
}

// MARK: - SwiftUI wrapper

struct PDFViewerView: NSViewRepresentable {
    let student: Student
    let assignment: Assignment
    let bundleURL: URL
    @Binding var tool: AnnotationTool
    var targetedRubricItem: RubricItem?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnnotatingPDFView {
        let view = AnnotatingPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysAsBook = false
        view.annotationDelegate = context.coordinator
        view.autoresizingMask = [.width, .height]
        context.coordinator.pdfView = view

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.highlightSelection),
            name: AnnotationToolbar.highlightNotification,
            object: nil
        )
        return view
    }

    func updateNSView(_ pdfView: AnnotatingPDFView, context: Context) {
        if pdfView.currentTool != tool {
            pdfView.selectAnnotation(nil)
        }
        pdfView.currentTool = tool
        context.coordinator.toolBinding = _tool
        context.coordinator.student = student
        context.coordinator.rubricItems = assignment.rubricItems.sorted { $0.order < $1.order }
        context.coordinator.targetedRubricItem = targetedRubricItem

        let url: URL? = student.pdfRelativePath.isEmpty
            ? nil
            : bundleURL.appendingPathComponent(student.pdfRelativePath)

        if url != context.coordinator.loadedURL {
            context.coordinator.loadedURL = url
            if let url {
                pdfView.document = PDFDocument(url: url)
                context.coordinator.currentURL = url
                pdfView.autoScales = true
                DispatchQueue.main.async { pdfView.autoScales = false }
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, AnnotationDelegate {
        weak var pdfView: AnnotatingPDFView?
        var loadedURL: URL?
        var currentURL: URL?
        var toolBinding: Binding<AnnotationTool>?
        var student: Student?
        var rubricItems: [RubricItem] = []
        var targetedRubricItem: RubricItem?

        func pdfView(_ view: AnnotatingPDFView, didClickAt point: CGPoint, on page: PDFPage, tool: AnnotationTool) {
            switch tool {
            case .text:         showTextDialog(page: page, at: point)
            case .stamp(let t): addStamp(type: t, page: page, at: point)
            default: break
            }
        }

        func pdfViewDidModify(_ view: AnnotatingPDFView) { savePDF() }

        func pdfViewDidRequestTool(_ tool: AnnotationTool) {
            DispatchQueue.main.async { [weak self] in
                self?.toolBinding?.wrappedValue = tool
            }
        }

        func pdfViewApplyHighlight(_ view: AnnotatingPDFView) {
            highlightSelection()
        }

        // Called by toolbar button notification AND by H key press
        @objc func highlightSelection() {
            guard let pdfView, let selection = pdfView.currentSelection else { return }
            for page in selection.pages {
                let bounds = selection.bounds(for: page)
                guard bounds != .zero else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                // Use full opacity — PDF highlight blend mode handles the translucency on render
                annotation.color = NSColor(calibratedRed: 1, green: 0.85, blue: 0, alpha: 1)
                addAnnotationWithUndo(annotation, to: page)
            }
            pdfView.clearSelection()
        }

        func removeAnnotationWithUndo(_ annotation: PDFAnnotation) {
            guard let page = annotation.page else { return }
            page.removeAnnotation(annotation)
            pdfView?.undoManager?.registerUndo(withTarget: self) { coord in
                coord.addAnnotationWithUndo(annotation, to: page)
            }
            pdfView?.undoManager?.setActionName("Delete Annotation")
            savePDF()
        }

        private func addAnnotationWithUndo(_ annotation: PDFAnnotation, to page: PDFPage) {
            page.addAnnotation(annotation)
            pdfView?.undoManager?.registerUndo(withTarget: self) { coord in
                coord.removeAnnotationWithUndo(annotation)
            }
            pdfView?.undoManager?.setActionName("Add Annotation")
            savePDF()
        }

        private func showTextDialog(page: PDFPage, at point: CGPoint) {
            let alert = NSAlert()
            alert.messageText = "Add Comment"

            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
            let textView = NSTextView(frame: scrollView.bounds)
            textView.isEditable = true
            textView.font = NSFont.systemFont(ofSize: 13)
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            alert.accessoryView = scrollView
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let lineCount = max(1, CGFloat(text.components(separatedBy: "\n").count))
            let height = max(30, lineCount * 15 + 10)
            let bounds = CGRect(x: point.x, y: point.y - height, width: 200, height: height)

            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = text
            annotation.font = NSFont.systemFont(ofSize: 11)
            annotation.color = NSColor(calibratedRed: 1, green: 0.95, blue: 0.4, alpha: 0.9)
            annotation.fontColor = .black
            addAnnotationWithUndo(annotation, to: page)
        }

        private func addStamp(type: AnnotationTool.StampType, page: PDFPage, at point: CGPoint) {
            let size: CGFloat = 36
            let bounds = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = type.symbol
            annotation.font = NSFont.systemFont(ofSize: 26)
            annotation.color = .clear
            annotation.alignment = .center
            annotation.isReadOnly = true
            addAnnotationWithUndo(annotation, to: page)
        }

        // MARK: - Grade stamping

        func pdfViewHandleGradeClick(at point: CGPoint, on page: PDFPage) {
            guard let item = targetedRubricItem else { return }  // no-op if nothing targeted
            placeGradeStamp(for: item, at: point, on: page)
        }

        private func placeGradeStamp(for item: RubricItem, at point: CGPoint, on page: PDFPage) {
            guard let doc = pdfView?.document else { return }

            // Remove any existing stamp for this problem across all pages
            let tag = "grader.grade.\(item.id.uuidString)"
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                p.annotations.filter { $0.userName == tag }.forEach { p.removeAnnotation($0) }
            }

            let score = student?.scores.first { $0.rubricItemID == item.id }
            let earnedText = score?.points.map { fmtPts($0) } ?? "—"
            let text = "\(item.name)\n\(earnedText) / \(fmtPts(item.maxPoints))"

            let w: CGFloat = 120, h: CGFloat = 36
            let bounds = CGRect(x: point.x, y: point.y - h / 2, width: w, height: h)
            let ann = makeGradeAnnotation(text: text, bounds: bounds, tag: tag)
            page.addAnnotation(ann)

            updateSummary()
            savePDF()
        }

        private func updateSummary() {
            guard let doc = pdfView?.document,
                  let page1 = doc.page(at: 0),
                  let student = student else { return }

            let summaryTag = "grader.summary"
            page1.annotations.filter { $0.userName == summaryTag }.forEach { page1.removeAnnotation($0) }

            guard !rubricItems.isEmpty else { return }

            var lines = ["Grade Summary"]
            var totalEarned = 0.0, totalMax = 0.0
            for item in rubricItems {
                let score = student.scores.first { $0.rubricItemID == item.id }
                let earned = score?.points
                totalEarned += earned ?? 0
                totalMax += item.maxPoints
                let earnedStr = earned.map { fmtPts($0) } ?? "—"
                lines.append("\(item.name): \(earnedStr)/\(fmtPts(item.maxPoints))")
            }
            lines.append("─────────────")
            let pct = totalMax > 0 ? String(format: " (%.0f%%)", totalEarned / totalMax * 100) : ""
            lines.append("Total: \(fmtPts(totalEarned))/\(fmtPts(totalMax))\(pct)")

            let lineCount = CGFloat(lines.count)
            let fSize: CGFloat = 10
            let h = lineCount * fSize * 1.5 + 8
            let w: CGFloat = 160
            let pageH = page1.bounds(for: .mediaBox).height
            let bounds = CGRect(x: 10, y: pageH - h - 10, width: w, height: h)

            let ann = makeGradeAnnotation(text: lines.joined(separator: "\n"), bounds: bounds, tag: summaryTag)
            page1.addAnnotation(ann)
        }

        private func makeGradeAnnotation(text: String, bounds: CGRect, tag: String) -> PDFAnnotation {
            let ann = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            ann.contents = text
            ann.font = NSFont.systemFont(ofSize: 10)
            ann.fontColor = NSColor(red: 0, green: 0.40, blue: 0.12, alpha: 1)  // dark green
            ann.color = NSColor.white
            ann.userName = tag
            ann.isReadOnly = true
            let border = PDFBorder()
            border.lineWidth = 0.75
            ann.border = border
            return ann
        }

        private func fmtPts(_ val: Double) -> String {
            val.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(val)) : String(format: "%.1f", val)
        }

        private func savePDF() {
            guard let url = currentURL,
                  let data = pdfView?.document?.dataRepresentation() else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}


// MARK: - Annotation delegate protocol

protocol AnnotationDelegate: AnyObject {
    func pdfView(_ view: AnnotatingPDFView, didClickAt point: CGPoint, on page: PDFPage, tool: AnnotationTool)
    func pdfViewDidModify(_ view: AnnotatingPDFView)
    func pdfViewDidRequestTool(_ tool: AnnotationTool)
    func pdfViewApplyHighlight(_ view: AnnotatingPDFView)
    func pdfViewHandleGradeClick(at point: CGPoint, on page: PDFPage)
    func removeAnnotationWithUndo(_ annotation: PDFAnnotation)
}

// MARK: - Custom PDFView

final class AnnotatingPDFView: PDFView {
    var currentTool: AnnotationTool = .pointer
    weak var annotationDelegate: AnnotationDelegate?

    // Tracks the "selected" annotation in pointer mode; stored color for visual highlight
    private var selectedAnnotation: PDFAnnotation?
    private var selectedOriginalColor: NSColor?

    override func mouseDown(with event: NSEvent) {
        let loc = pageLocation(for: event)

        switch currentTool {
        case .pointer:
            let tapped = loc.flatMap { $0.page.annotation(at: $0.point) }
            selectAnnotation(tapped)
            super.mouseDown(with: event)

        case .delete:
            if let loc, let hit = loc.page.annotation(at: loc.point) {
                selectAnnotation(nil)
                annotationDelegate?.removeAnnotationWithUndo(hit)
            }

        case .grade:
            if let loc {
                annotationDelegate?.pdfViewHandleGradeClick(at: loc.point, on: loc.page)
            }

        case .highlight:
            super.mouseDown(with: event)

        case .text, .stamp:
            guard let loc else { super.mouseDown(with: event); return }
            annotationDelegate?.pdfView(self, didClickAt: loc.point, on: loc.page, tool: currentTool)
        }
    }

    // Right-click → Delete works regardless of current tool
    override func menu(for event: NSEvent) -> NSMenu? {
        if let loc = pageLocation(for: event),
           let annotation = loc.page.annotation(at: loc.point) {
            selectAnnotation(annotation)
            let menu = NSMenu()
            let item = NSMenuItem(title: "Delete Annotation",
                                  action: #selector(deleteSelected), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }
        return super.menu(for: event)
    }

    @objc private func deleteSelected() {
        guard let annotation = selectedAnnotation else { return }
        selectAnnotation(nil)
        annotationDelegate?.removeAnnotationWithUndo(annotation)
    }

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        // Restore previous selection's original color
        if let prev = selectedAnnotation, let orig = selectedOriginalColor {
            prev.color = orig
        }
        selectedAnnotation = annotation
        selectedOriginalColor = annotation?.color

        if let annotation {
            // Blue tint to signal selection; semi-transparent so content stays readable
            annotation.color = NSColor.systemBlue.withAlphaComponent(0.25)
        }
    }

    override func keyDown(with event: NSEvent) {
        let ch = event.charactersIgnoringModifiers?.lowercased()

        // Keys only fire when PDF view has focus — won't interfere with sidebar list
        switch ch {
        case "c": annotationDelegate?.pdfViewDidRequestTool(.text);              return
        case "h": annotationDelegate?.pdfViewApplyHighlight(self);               return
        case "d": annotationDelegate?.pdfViewDidRequestTool(.delete);            return
        case "g": annotationDelegate?.pdfViewDidRequestTool(.grade);             return
        case "v": annotationDelegate?.pdfViewDidRequestTool(.stamp(.correct));   return
        case "x": annotationDelegate?.pdfViewDidRequestTool(.stamp(.incorrect)); return
        case "k": annotationDelegate?.pdfViewDidRequestTool(.stamp(.partial));   return
        default: break
        }

        // ⌫ / Forward-delete removes the currently selected annotation
        if event.keyCode == 51 || event.keyCode == 117 {
            if let annotation = selectedAnnotation {
                selectAnnotation(nil)
                annotationDelegate?.removeAnnotationWithUndo(annotation)
                return
            }
        }

        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    private func pageLocation(for event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }
}
