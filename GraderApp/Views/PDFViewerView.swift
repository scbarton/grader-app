import SwiftUI
import PDFKit
import AppKit

extension Notification.Name {
    static let navigateStudent    = Notification.Name("GraderApp.navigateStudent")
    static let navigateRubricItem = Notification.Name("GraderApp.navigateRubricItem")
}

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

        // Cmd+Space focuses the PDF view from anywhere (score panel, sidebar, etc.)
        context.coordinator.focusMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods == .command, event.keyCode == 49 {  // 49 = Space
                view?.window?.makeFirstResponder(view)
                return nil  // consume event
            }
            return event
        }
        return view
    }

    static func dismantleNSView(_ nsView: AnnotatingPDFView, coordinator: Coordinator) {
        if let monitor = coordinator.focusMonitor {
            NSEvent.removeMonitor(monitor)
            coordinator.focusMonitor = nil
        }
    }

    func updateNSView(_ pdfView: AnnotatingPDFView, context: Context) {
        if pdfView.currentTool != tool {
            pdfView.selectAnnotation(nil)
            // Return focus to PDF view after toolbar button clicks so key shortcuts keep working
            DispatchQueue.main.async { pdfView.window?.makeFirstResponder(pdfView) }
        }
        pdfView.currentTool = tool
        context.coordinator.toolBinding = _tool
        context.coordinator.student = student
        context.coordinator.rubricItems = assignment.rubricItems.sorted { $0.order < $1.order }

        // Scroll to grade stamp when targeted problem changes
        let oldTargetID = context.coordinator.targetedRubricItem?.id
        context.coordinator.targetedRubricItem = targetedRubricItem
        if targetedRubricItem?.id != oldTargetID, let item = targetedRubricItem {
            context.coordinator.scrollToGradeStamp(for: item)
        }

        let url: URL? = student.pdfRelativePath.isEmpty
            ? nil
            : bundleURL.appendingPathComponent(student.pdfRelativePath)

        let newSnapshot = Dictionary(uniqueKeysWithValues: student.scores.map { ($0.rubricItemID, $0.points) })

        if url != context.coordinator.loadedURL {
            // Student changed: save the current PDF before switching so any pending
            // score updates are flushed to disk, then load the new PDF.
            context.coordinator.savePDFIfNeeded()
            context.coordinator.scoreSnapshot = newSnapshot
            context.coordinator.loadedURL = url
            if let url {
                pdfView.document = PDFDocument(url: url)
                context.coordinator.currentURL = url
                pdfView.autoScales = true
                DispatchQueue.main.async {
                    pdfView.autoScales = false
                    context.coordinator.refreshGradeAnnotations()
                }
            }
            DispatchQueue.main.async { pdfView.window?.makeFirstResponder(pdfView) }
        } else if newSnapshot != context.coordinator.scoreSnapshot {
            // Same student, scores changed: update stamps in the current document.
            context.coordinator.scoreSnapshot = newSnapshot
            if context.coordinator.pdfView?.document != nil {
                context.coordinator.refreshGradeAnnotations()
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
        var scoreSnapshot: [UUID: Double?] = [:]
        var focusMonitor: Any?

        // Keyboard grade input state
        private var gradeInputBuffer = ""
        private var gradeInputItemID: UUID? = nil
        private var gradeInputStudentID: UUID? = nil

        func pdfView(_ view: AnnotatingPDFView, didClickAt point: CGPoint, on page: PDFPage, tool: AnnotationTool) {
            switch tool {
            case .text:         showTextAnnotation(page: page, at: point)
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

        private func showTextAnnotation(page: PDFPage, at point: CGPoint) {
            pdfView?.showInlineComment(at: point, on: page) { [weak self] text in
                guard let self else { return }
                let lineCount = max(1, CGFloat(text.components(separatedBy: "\n").count))
                let height = max(30, lineCount * 15 + 10)
                let bounds = CGRect(x: point.x, y: point.y - height, width: 200, height: height)
                let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                annotation.contents = text
                annotation.color = .clear
                annotation.fontColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 1)
                annotation.font = NSFont.systemFont(ofSize: 16)
                self.addAnnotationWithUndo(annotation, to: page)
            }
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

        func refreshGradeAnnotations() {
            guard let doc = pdfView?.document, let student = student else { return }
            var didUpdate = false
            for item in rubricItems {
                let tag = "grader.grade.\(item.id.uuidString)"
                let score = student.scores.first { $0.rubricItemID == item.id }
                let earnedText = score?.points.map { fmtPts($0) } ?? "—"
                let newText = "\(item.name)\n\(earnedText) / \(fmtPts(item.maxPoints))"
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    for ann in page.annotations where ann.userName == tag {
                        if ann.contents != newText {
                            ann.contents = newText
                            didUpdate = true
                        }
                    }
                }
            }
            if updateSummary() { didUpdate = true }
            if didUpdate { savePDF() }
        }

        func scrollToGradeStamp(for item: RubricItem) {
            guard let doc = pdfView?.document else { return }
            let tag = "grader.grade.\(item.id.uuidString)"
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                if let ann = page.annotations.first(where: { $0.userName == tag }) {
                    let dest = PDFDestination(page: page, at: ann.bounds.origin)
                    pdfView?.go(to: dest)
                    return
                }
            }
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

            // On 90°/270° rotated pages the PDF axes are swapped, so swap w/h so the
            // stamp appears wide and short rather than skinny and tall
            let rotated = page.rotation % 360 == 90 || page.rotation % 360 == 270
            let (w, h): (CGFloat, CGFloat) = rotated ? (36, 120) : (120, 36)
            let bounds = CGRect(x: point.x, y: point.y - h / 2, width: w, height: h)
            let ann = makeGradeAnnotation(text: text, bounds: bounds, tag: tag)
            page.addAnnotation(ann)

            updateSummary()
            savePDF()
        }

        @discardableResult
        private func updateSummary() -> Bool {
            guard let doc = pdfView?.document,
                  let page1 = doc.page(at: 0),
                  let student = student,
                  !rubricItems.isEmpty else { return false }

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
            let newText = lines.joined(separator: "\n")

            let summaryTag = "grader.summary"

            if let existing = page1.annotations.first(where: { $0.userName == summaryTag }) {
                if existing.contents == newText { return false }
                existing.contents = newText
                return true
            }

            let lineCount = CGFloat(lines.count)
            let h = lineCount * 10 * 1.5 + 8
            let w: CGFloat = 160
            let pageRect = page1.bounds(for: .mediaBox)
            let bounds = CGRect(x: pageRect.width - w - 10, y: pageRect.height - h - 10, width: w, height: h)
            page1.addAnnotation(makeGradeAnnotation(text: newText, bounds: bounds, tag: summaryTag))
            return true
        }

        private func makeGradeAnnotation(text: String, bounds: CGRect, tag: String) -> PDFAnnotation {
            let ann = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            ann.contents = text
            ann.font = NSFont.systemFont(ofSize: 10)
            ann.fontColor = NSColor(red: 0, green: 0.40, blue: 0.12, alpha: 1)  // dark green
            // #FFFBB3 light yellow
            ann.color = NSColor(red: 1.0, green: 251/255, blue: 179/255, alpha: 1.0)
            ann.userName = tag
            ann.isReadOnly = true
            let border = PDFBorder()
            border.lineWidth = 0
            ann.border = border
            return ann
        }

        private func fmtPts(_ val: Double) -> String {
            val.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(val)) : String(format: "%.1f", val)
        }

        func handleGradeKey(_ event: NSEvent) -> Bool {
            let raw = event.charactersIgnoringModifiers ?? ""
            let isDigit = raw.count == 1 && raw.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            let isDot   = raw == "."
            let isBack  = event.keyCode == 51  // ⌫
            guard isDigit || isDot || isBack else { return false }
            guard let item = targetedRubricItem, let student = student else { return false }

            // Reset buffer when problem or student changes
            if item.id != gradeInputItemID || student.id != gradeInputStudentID {
                gradeInputBuffer = ""
                gradeInputItemID    = item.id
                gradeInputStudentID = student.id
            }

            if isDigit || isDot {
                if isDot && gradeInputBuffer.contains(".") { return true }  // one dot only
                gradeInputBuffer += raw
            } else {
                if gradeInputBuffer.isEmpty { return false }  // let annotation-delete handle ⌫
                gradeInputBuffer.removeLast()
            }

            guard let score = student.scores.first(where: { $0.rubricItemID == item.id }) else { return true }
            let parseStr = gradeInputBuffer.hasSuffix(".") ? String(gradeInputBuffer.dropLast()) : gradeInputBuffer
            if parseStr.isEmpty {
                score.points = nil
            } else if let value = Double(parseStr) {
                score.points = min(max(0, value), item.maxPoints)
            }
            return true
        }

        func savePDFIfNeeded() {
            savePDF()
        }

        private func savePDF() {
            guard let url = currentURL, let doc = pdfView?.document else { return }
            // Temporarily restore the selected annotation's real color before serializing
            // so the blue selection tint is never baked into the saved PDF
            let sel = pdfView?.selectedAnnotation
            let orig = pdfView?.selectedOriginalColor
            if let sel, let orig { sel.color = orig }
            let data = doc.dataRepresentation()
            if let sel { sel.color = NSColor.systemBlue.withAlphaComponent(0.25) }
            if let data { try? data.write(to: url, options: .atomic) }
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
    func handleGradeKey(_ event: NSEvent) -> Bool
}

// MARK: - Inline comment editor (NSTextView that commits on resign or Escape)

private final class InlineTextView: NSTextView {
    var onEnd: ((String, Bool) -> Void)?
    private var ended = false

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { end(cancelled: true); return }  // Escape → cancel
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            end(cancelled: false); return  // Cmd+Return → commit
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { end(cancelled: false) }
        return ok
    }

    private func end(cancelled: Bool) {
        guard !ended else { return }
        ended = true
        onEnd?(string, cancelled)
    }
}

// MARK: - Custom PDFView

final class AnnotatingPDFView: PDFView {
    var currentTool: AnnotationTool = .pointer
    weak var annotationDelegate: AnnotationDelegate?

    // Selection highlight — internal so savePDF can temporarily restore real color before serializing
    var selectedAnnotation: PDFAnnotation?
    var selectedOriginalColor: NSColor?

    // Drag state for pointer mode
    private var draggingAnnotation: PDFAnnotation?
    private var dragStartPagePoint: CGPoint?
    private var dragOriginalOrigin: CGPoint?

    // Inline comment editor overlay
    private var inlineEditorContainer: NSView?

    func showInlineComment(at pagePoint: CGPoint, on page: PDFPage, onCommit: @escaping (String) -> Void) {
        inlineEditorContainer?.removeFromSuperview()
        inlineEditorContainer = nil

        let viewPt = convert(pagePoint, from: page)
        let w: CGFloat = 200, h: CGFloat = 72

        let container = NSView(frame: NSRect(x: viewPt.x, y: viewPt.y, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 1, green: 251/255, blue: 179/255, alpha: 0.97).cgColor
        container.layer?.cornerRadius = 4
        container.layer?.borderWidth = 0.75
        container.layer?.borderColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 0.5).cgColor
        container.layer?.shadowOpacity = 0.18
        container.layer?.shadowRadius  = 6
        container.layer?.shadowOffset  = .zero

        let tv = InlineTextView(frame: container.bounds.insetBy(dx: 4, dy: 4))
        tv.autoresizingMask = [.width, .height]
        tv.isEditable = true
        tv.isRichText = false
        tv.isVerticallyResizable = true
        tv.font = NSFont.systemFont(ofSize: 13)
        tv.textColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 1)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.insertionPointColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 1)
        container.addSubview(tv)

        inlineEditorContainer = container
        addSubview(container)
        window?.makeFirstResponder(tv)

        tv.onEnd = { [weak self, weak container] text, cancelled in
            container?.removeFromSuperview()
            if let self, self.inlineEditorContainer === container { self.inlineEditorContainer = nil }
            self?.window?.makeFirstResponder(self)
            guard !cancelled else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { onCommit(trimmed) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking anywhere on the PDF view claims focus so key shortcuts always work
        if inlineEditorContainer == nil { window?.makeFirstResponder(self) }
        let loc = pageLocation(for: event)

        switch currentTool {
        case .pointer:
            let hit = loc.flatMap { $0.page.annotation(at: $0.point) }
            selectAnnotation(hit)
            if let hit, let loc {
                // Begin drag
                draggingAnnotation = hit
                dragStartPagePoint = loc.point
                dragOriginalOrigin = hit.bounds.origin
            } else {
                super.mouseDown(with: event)
            }

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

    override func mouseDragged(with event: NSEvent) {
        guard let ann = draggingAnnotation,
              let page = ann.page,
              let startPt = dragStartPagePoint,
              let origOrigin = dragOriginalOrigin else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        let pagePoint = convert(viewPoint, to: page)
        let dx = pagePoint.x - startPt.x
        let dy = pagePoint.y - startPt.y
        ann.bounds = CGRect(
            origin: CGPoint(x: origOrigin.x + dx, y: origOrigin.y + dy),
            size: ann.bounds.size
        )
    }

    override func mouseUp(with event: NSEvent) {
        if draggingAnnotation != nil {
            draggingAnnotation = nil
            dragStartPagePoint = nil
            dragOriginalOrigin = nil
            annotationDelegate?.pdfViewDidModify(self)  // saves PDF
        } else {
            super.mouseUp(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Cmd+Option+Up/Down: cycle through rubric problems
        if mods == [.command, .option] {
            switch event.keyCode {
            case 126: NotificationCenter.default.post(name: .navigateRubricItem, object: -1); return
            case 125: NotificationCenter.default.post(name: .navigateRubricItem, object:  1); return
            default: break
            }
        }

        // Cmd+Up/Down: navigate students
        if mods == .command {
            switch event.keyCode {
            case 126: NotificationCenter.default.post(name: .navigateStudent, object: -1); return
            case 125: NotificationCenter.default.post(name: .navigateStudent, object:  1); return
            default: break
            }
        }

        // Digits and "." → direct grade entry; ⌫ only if no annotation is selected
        if mods.isEmpty || mods == .shift {
            let raw = event.charactersIgnoringModifiers ?? ""
            let isDigitOrDot = raw.count == 1 &&
                raw.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.union(.init(charactersIn: ".")).contains($0) }
            let isBackForGrade = event.keyCode == 51 && selectedAnnotation == nil
            if (isDigitOrDot || isBackForGrade) && annotationDelegate?.handleGradeKey(event) == true { return }
        }

        let ch = event.charactersIgnoringModifiers?.lowercased()

        // Annotation tool shortcuts (PDF view must have focus — won't fire in sidebar)
        switch ch {
        case "m": annotationDelegate?.pdfViewDidRequestTool(.pointer);            return
        case "c": annotationDelegate?.pdfViewDidRequestTool(.text);              return
        case "h": annotationDelegate?.pdfViewApplyHighlight(self);               return
        case "d": annotationDelegate?.pdfViewDidRequestTool(.delete);            return
        case "g": annotationDelegate?.pdfViewDidRequestTool(.grade);             return
        case "r":
            if let page = currentPage {
                page.rotation = (page.rotation + 90) % 360
                annotationDelegate?.pdfViewDidModify(self)
            }
            return
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
