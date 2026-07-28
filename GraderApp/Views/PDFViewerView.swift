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
    case ink
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
        context.coordinator.assignment = assignment
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
            // Student changed: clear selection (avoids touching a stale annotation's color
            // in savePDF), save the current PDF, then load the new one.
            pdfView.selectAnnotation(nil)
            context.coordinator.savePDFIfNeeded()
            context.coordinator.scoreSnapshot = newSnapshot
            context.coordinator.loadedURL = url
            if let url {
                pdfView.document = PDFDocument(url: url)
                context.coordinator.currentURL = url
                pdfView.autoScales = true
                DispatchQueue.main.async {
                    pdfView.autoScales = false
                    DispatchQueue.main.async {
                        context.coordinator.ensureQuizStamps()
                        context.coordinator.refreshAnnotationColors()
                        context.coordinator.scrollToRelevantStamp()
                    }
                }
            }
            DispatchQueue.main.async { pdfView.window?.makeFirstResponder(pdfView) }
        } else if newSnapshot.compactMapValues({ $0 }) != context.coordinator.scoreSnapshot.compactMapValues({ $0 }) {
            // Same student, actual point values changed (ignore nil-score object creation).
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
        var assignment: Assignment?
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

        func pdfViewDidDrawHighlight(bounds: CGRect, on page: PDFPage) {
            let ann = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            ann.color = NSColor(calibratedRed: 1, green: 0.85, blue: 0, alpha: 1)
            addAnnotationWithUndo(ann, to: page)
        }

        // Freehand handwriting (Z). `points` are in page coordinates. Stored as a PDF /Ink
        // annotation: bounds = padded stroke bbox, path added relative to bounds origin.
        static let inkColor = NSColor(red: 0.55, green: 0.15, blue: 0.75, alpha: 1)  // violet
        static let inkLineWidth: CGFloat = 1.5

        func pdfViewDidDrawInk(points: [CGPoint], on page: PDFPage) {
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for pt in points.dropFirst() { path.line(to: pt) }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.lineWidth = Self.inkLineWidth

            let pad = Self.inkLineWidth + 2
            let bbox = path.bounds.insetBy(dx: -pad, dy: -pad)
            let ann = PDFAnnotation(bounds: bbox, forType: .ink, withProperties: nil)
            ann.color = Self.inkColor
            let border = PDFBorder()
            border.lineWidth = Self.inkLineWidth
            ann.border = border
            // PDFKit interprets the added path relative to the annotation's bounds origin.
            let local = path.copy() as! NSBezierPath
            local.transform(using: AffineTransform(translationByX: -bbox.origin.x, byY: -bbox.origin.y))
            ann.add(local)
            addAnnotationWithUndo(ann, to: page)
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
                let font = NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10)
                let rotated = page.rotation % 360 == 90 || page.rotation % 360 == 270
                let measured = (text as NSString).boundingRect(
                    with: CGSize(width: 192, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                let textExtent = max(30, ceil(measured.height) + 12)
                let (w, h): (CGFloat, CGFloat) = rotated ? (textExtent, 200) : (200, textExtent)
                let bounds = CGRect(x: point.x, y: point.y - h / 2, width: w, height: h)
                let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
                annotation.contents = text
                annotation.color = NSColor(red: 0.95, green: 0.92, blue: 1.0, alpha: 0.5)
                annotation.fontColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 1)
                annotation.font = NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10)
                self.addAnnotationWithUndo(annotation, to: page)
            }
        }

        private func addStamp(type: AnnotationTool.StampType, page: PDFPage, at point: CGPoint) {
            let size: CGFloat = 24
            let bounds = CGRect(x: point.x, y: point.y - size / 2, width: size, height: size)
            let annotation = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            annotation.contents = type.symbol
            annotation.font = NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)
            annotation.color = .clear
            annotation.alignment = .center
            annotation.userName = "grader.emoji"
            addAnnotationWithUndo(annotation, to: page)
        }

        // MARK: - Grade stamping

        func pdfViewHandleGradeClick(at point: CGPoint, on page: PDFPage) {
            guard let item = targetedRubricItem else { return }  // no-op if nothing targeted
            placeGradeStamp(for: item, at: point, on: page)
        }

        func refreshGradeAnnotations() {
            guard let doc = pdfView?.document, let student = student else { return }
            ensureQuizStamps()
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
                            ann.color = NSColor(red: 1.0, green: 251/255, blue: 179/255, alpha: 0.5)
                            didUpdate = true
                        }
                    }
                }
            }
            if updateSummary() { didUpdate = true }
            if didUpdate { savePDF() }
        }

        func clearGraderAnnotations() {
            guard let doc = pdfView?.document else { return }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let grader = page.annotations.filter { $0.userName?.hasPrefix("grader.") == true }
                grader.forEach { page.removeAnnotation($0) }
            }
            savePDF()
        }

        // On load: re-apply each FreeText annotation's intended background color, WITH its alpha.
        //
        // A PDF annotation's color entry (/C) is RGB-only and cannot store alpha, so a translucent
        // annotation reloads with an opaque color and PDFKit then regenerates an opaque appearance —
        // comments/grade stamps lose their transparency and emoji gain a background after a round-trip.
        // Re-assigning `ann.color = ann.color` does NOT help (it re-reads the already-opaque value);
        // we must set the intended color with its alpha explicitly, keyed by annotation type.
        //
        // This marks the annotation dirty (forcing appearance regeneration on the next save). That is
        // safe from the "baking" bug because iPad handwriting-ink pages are rasterized at import
        // (see PDFScaler.rasterizeInkIfNeeded) — regeneration only flattens into content on vector-ink
        // pages, which no longer exist after import.
        static let commentColor = NSColor(red: 0.95, green: 0.92, blue: 1.0, alpha: 0.5)
        static let gradeColor   = NSColor(red: 1.0, green: 251/255, blue: 179/255, alpha: 0.5)
        static let summaryColor = NSColor(red: 1.0, green: 251/255, blue: 179/255, alpha: 1.0)

        func refreshAnnotationColors() {
            guard let doc = pdfView?.document else { return }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                for ann in page.annotations {
                    if ann.isReadOnly { ann.isReadOnly = false }
                    // Only FreeText annotations (comments, grade stamps, summary, emoji) carry a
                    // background color that loses alpha; highlights use a blend mode and are left alone.
                    guard let t = ann.type, t.hasSuffix("FreeText") else { continue }
                    switch ann.userName {
                    case "grader.emoji":
                        ann.color = .clear
                    case "grader.summary":
                        ann.color = Coordinator.summaryColor
                    case let name? where name.hasPrefix("grader."):
                        ann.color = Coordinator.gradeColor
                    default:
                        ann.color = Coordinator.commentColor
                    }
                }
            }
        }

        // TODO: moving a quiz grade stamp with the pointer tool doesn't update the stored
        // position or propagate to other students — re-placing with the grade tool is the fix.

        // Scroll so the annotation is visible with ~2 cm of space above it.
        private func scrollAbove(_ ann: PDFAnnotation, on page: PDFPage) {
            let abovePts: CGFloat = 57  // ~2 cm in PDF points
            let y = min(ann.bounds.maxY + abovePts, page.bounds(for: .mediaBox).maxY)
            pdfView?.go(to: PDFDestination(page: page, at: CGPoint(x: ann.bounds.midX, y: y)))
        }

        func scrollToGradeStamp(for item: RubricItem) {
            guard let doc = pdfView?.document else { return }
            let tag = "grader.grade.\(item.id.uuidString)"
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                if let ann = page.annotations.first(where: { $0.userName == tag }) {
                    scrollAbove(ann, on: page)
                    return
                }
            }
        }

        func scrollToRelevantStamp() {
            guard let doc = pdfView?.document else { return }
            // Try the targeted rubric item first
            if let item = targetedRubricItem {
                let tag = "grader.grade.\(item.id.uuidString)"
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    if let ann = page.annotations.first(where: { $0.userName == tag }) {
                        scrollAbove(ann, on: page)
                        return
                    }
                }
            }
            // Fallback: last grade stamp by page order (grading proceeds top to bottom)
            for i in stride(from: doc.pageCount - 1, through: 0, by: -1) {
                guard let page = doc.page(at: i) else { continue }
                if let ann = page.annotations.first(where: { $0.userName?.hasPrefix("grader.grade.") == true }) {
                    scrollAbove(ann, on: page)
                    return
                }
            }
        }

        private func placeGradeStamp(for item: RubricItem, at point: CGPoint, on page: PDFPage) {
            guard let doc = pdfView?.document else { return }

            // Collect and remove any existing stamp for this problem (saved for undo)
            let tag = "grader.grade.\(item.id.uuidString)"
            var previousStamps: [(PDFPage, PDFAnnotation)] = []
            for i in 0..<doc.pageCount {
                guard let p = doc.page(at: i) else { continue }
                let existing = p.annotations.filter { $0.userName == tag }
                previousStamps.append(contentsOf: existing.map { (p, $0) })
                existing.forEach { p.removeAnnotation($0) }
            }

            // Quiz: save canonical stamp position; capture previous for undo
            let prevPageIndex = item.stampPageIndex
            let prevX = item.stampX
            let prevY = item.stampY
            if assignment?.category == .quiz {
                item.stampPageIndex = doc.index(for: page)
                item.stampX = Double(point.x)
                item.stampY = Double(point.y)
            }

            let score = student?.scores.first { $0.rubricItemID == item.id }
            let earnedText = score?.points.map { fmtPts($0) } ?? "—"
            let text = "\(item.name)\n\(earnedText) / \(fmtPts(item.maxPoints))"

            // On 90°/270° rotated pages the PDF axes are swapped, so swap w/h so the
            // stamp appears wide and short rather than skinny and tall
            let rotated = page.rotation % 360 == 90 || page.rotation % 360 == 270
            let (w, h): (CGFloat, CGFloat) = rotated ? (36, 60) : (60, 36)
            let bounds = CGRect(x: point.x, y: point.y - h / 2, width: w, height: h)
            let ann = makeGradeAnnotation(text: text, bounds: bounds, tag: tag)
            page.addAnnotation(ann)

            pdfView?.undoManager?.registerUndo(withTarget: self) { coord in
                page.removeAnnotation(ann)
                for (oldPage, oldAnn) in previousStamps {
                    oldPage.addAnnotation(oldAnn)
                }
                if coord.assignment?.category == .quiz {
                    item.stampPageIndex = prevPageIndex
                    item.stampX = prevX
                    item.stampY = prevY
                }
                coord.updateSummary()
                coord.savePDF()
            }
            pdfView?.undoManager?.setActionName("Place Grade Stamp")

            updateSummary()
            savePDF()
        }

        func ensureQuizStamps() {
            guard assignment?.category == .quiz,
                  let doc = pdfView?.document,
                  let student = student else { return }
            var didPlace = false
            for item in rubricItems {
                guard let pageIndex = item.stampPageIndex,
                      let x = item.stampX,
                      let y = item.stampY,
                      let page = doc.page(at: pageIndex) else { continue }
                let tag = "grader.grade.\(item.id.uuidString)"
                let alreadyPlaced = (0..<doc.pageCount).contains { i in
                    doc.page(at: i)?.annotations.contains { $0.userName == tag } == true
                }
                guard !alreadyPlaced else { continue }
                let score = student.scores.first { $0.rubricItemID == item.id }
                let earnedText = score?.points.map { fmtPts($0) } ?? "—"
                let text = "\(item.name)\n\(earnedText) / \(fmtPts(item.maxPoints))"
                let rotated = page.rotation % 360 == 90 || page.rotation % 360 == 270
                let (w, h): (CGFloat, CGFloat) = rotated ? (36, 60) : (60, 36)
                let bounds = CGRect(x: CGFloat(x), y: CGFloat(y) - h / 2, width: w, height: h)
                page.addAnnotation(makeGradeAnnotation(text: text, bounds: bounds, tag: tag))
                didPlace = true
            }
            if didPlace { savePDF() }
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

            let summaryTag = AnnotatingPDFView.summaryTag

            // Match either the opaque ("grader.summary") or toggled-translucent
            // ("grader.summary.translucent") summary so we update in place, never duplicate,
            // and preserve the user's chosen transparency.
            if let existing = page1.annotations.first(where: { $0.userName?.hasPrefix(summaryTag) == true }) {
                if existing.contents == newText { return false }
                existing.contents = newText
                return true
            }

            let lineCount = CGFloat(lines.count)
            let h = lineCount * 10 * 1.5 + 8
            let w: CGFloat = 160
            let pageRect = page1.bounds(for: .mediaBox)
            let bounds = CGRect(x: pageRect.width - w - 10, y: pageRect.height - h - 10, width: w, height: h)
            page1.addAnnotation(makeGradeAnnotation(text: newText, bounds: bounds, tag: summaryTag, alpha: 1.0))
            return true
        }

        private func makeGradeAnnotation(text: String, bounds: CGRect, tag: String, alpha: CGFloat = 0.5) -> PDFAnnotation {
            let ann = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            ann.contents = text
            ann.font = NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10)
            ann.fontColor = NSColor(red: 0, green: 0.40, blue: 0.12, alpha: 1)  // dark green
            ann.color = NSColor(red: 1.0, green: 251/255, blue: 179/255, alpha: alpha)
            ann.userName = tag
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
            // Only the blue pointer-selection tint must be stripped before serializing; a
            // handle-selected comment keeps its real color (selectionTinted == false).
            let tinted = pdfView?.selectionTinted ?? false
            let sel = pdfView?.selectedAnnotation
            let orig = pdfView?.selectedOriginalColor
            if tinted, let sel, let orig { sel.color = orig }
            let data = doc.dataRepresentation()
            if tinted, let sel { sel.color = NSColor.systemBlue.withAlphaComponent(0.25) }
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
    func pdfViewDidDrawHighlight(bounds: CGRect, on page: PDFPage)
    func pdfViewDidDrawInk(points: [CGPoint], on page: PDFPage)
    func pdfViewHandleGradeClick(at point: CGPoint, on page: PDFPage)
    func removeAnnotationWithUndo(_ annotation: PDFAnnotation)
    func handleGradeKey(_ event: NSEvent) -> Bool
}

// MARK: - Freehand ink live-preview overlay

/// Transparent, non-interactive subview that draws the in-progress handwriting stroke in view
/// coordinates while the mouse is down. Not layer-backed, so it shares the PDFView's unflipped
/// coordinate space (no vertical flip to correct).
private final class InkOverlayView: NSView {
    var points: [CGPoint] = [] { didSet { needsDisplay = true } }
    var strokeColor: NSColor = .systemRed
    var lineWidth: CGFloat = 1.5

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never intercept the drag

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        strokeColor.setStroke()
        path.stroke()
    }
}

// MARK: - Comment selection handles overlay

/// The four resize corners of a selected comment box. Corners are indexed to match
/// `CommentSelectionView.handleRects(for:)` so a hit index maps straight to a corner.
private enum HandleCorner: Int {
    case bottomLeft, bottomRight, topLeft, topRight

    var opposite: HandleCorner {
        switch self {
        case .bottomLeft:  .topRight
        case .bottomRight: .topLeft
        case .topLeft:     .bottomRight
        case .topRight:    .bottomLeft
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        let r = rect.standardized
        switch self {
        case .bottomLeft:  return CGPoint(x: r.minX, y: r.minY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
        case .topLeft:     return CGPoint(x: r.minX, y: r.maxY)
        case .topRight:    return CGPoint(x: r.maxX, y: r.maxY)
        }
    }
}

/// Transparent, non-interactive subview that draws a selected comment's bounding box and its
/// four corner resize handles, in the PDFView's (unflipped) view coordinate space. Like
/// `InkOverlayView`, it never intercepts mouse events — the parent view owns hit-testing.
private final class CommentSelectionView: NSView {
    var boxRect: CGRect = .zero { didSet { needsDisplay = true } }

    static let handleSize: CGFloat = 9
    static let strokeColor = NSColor(red: 0.55, green: 0.15, blue: 0.75, alpha: 0.9)  // violet

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // parent owns hit-testing

    /// Corner handle rects (view space), indexed to match `HandleCorner`.
    static func handleRects(for box: CGRect) -> [CGRect] {
        let s = handleSize
        let b = box.standardized
        let centers = [
            CGPoint(x: b.minX, y: b.minY),  // bottomLeft
            CGPoint(x: b.maxX, y: b.minY),  // bottomRight
            CGPoint(x: b.minX, y: b.maxY),  // topLeft
            CGPoint(x: b.maxX, y: b.maxY),  // topRight
        ]
        return centers.map { CGRect(x: $0.x - s / 2, y: $0.y - s / 2, width: s, height: s) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard boxRect.width > 0, boxRect.height > 0 else { return }
        Self.strokeColor.setStroke()

        let border = NSBezierPath(rect: boxRect.standardized)
        border.lineWidth = 1
        border.setLineDash([4, 3], count: 2, phase: 0)
        border.stroke()

        for r in Self.handleRects(for: boxRect) {
            let hp = NSBezierPath(rect: r)
            NSColor.white.setFill()
            hp.fill()
            hp.lineWidth = 1
            hp.stroke()
        }
    }
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

    // Drag state for highlight rectangle
    private var highlightDragPage: PDFPage?
    private var highlightDragStartPagePoint: CGPoint?
    private var highlightRubberBand: NSView?

    // Drag state for freehand handwriting (ink)
    private var inkDragPage: PDFPage?
    private var inkPoints: [CGPoint] = []          // page coordinates
    private var inkOverlay: NSView?                // live stroke preview

    // Inline comment editor overlay
    private var inlineEditorContainer: NSView?

    // Comment selection (Comment tool): a selected comment shows corner handles and can be
    // moved/resized. `selectionTinted` distinguishes the blue pointer-selection (which savePDF
    // must un-tint before serializing) from the handle-selection (real color, never tinted).
    var commentSelection: PDFAnnotation?
    var selectionTinted = false
    private var commentSelectionPage: PDFPage?
    private var commentHandles: NSView?
    private var resizingAnnotation: PDFAnnotation?
    private var resizeAnchorPagePoint: CGPoint = .zero
    private var resizeOriginalBounds: CGRect = .zero
    private var clipObserver: Any?
    private var scaleObserver: Any?

    func showInlineComment(at pagePoint: CGPoint, on page: PDFPage, initialText: String = "", onCommit: @escaping (String) -> Void, onCancel: (() -> Void)? = nil) {
        inlineEditorContainer?.removeFromSuperview()
        inlineEditorContainer = nil

        let viewPt = convert(pagePoint, from: page)
        let w: CGFloat = 200, h: CGFloat = 90

        let container = NSView(frame: NSRect(x: viewPt.x, y: viewPt.y - h / 2, width: w, height: h))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.95, green: 0.92, blue: 1.0, alpha: 0.85).cgColor
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
        tv.font = NSFont.systemFont(ofSize: 16)
        tv.textColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 1)
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.insertionPointColor = NSColor(red: 0.45, green: 0, blue: 0.6, alpha: 1)
        tv.string = initialText
        container.addSubview(tv)

        inlineEditorContainer = container
        addSubview(container)
        window?.makeFirstResponder(tv)

        tv.onEnd = { [weak self, weak container] text, cancelled in
            container?.removeFromSuperview()
            if let self, self.inlineEditorContainer === container { self.inlineEditorContainer = nil }
            self?.window?.makeFirstResponder(self)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cancelled && !trimmed.isEmpty {
                onCommit(trimmed)
            } else {
                onCancel?()
            }
        }
    }

    private func editTextAnnotation(_ annotation: PDFAnnotation, on page: PDFPage) {
        let originalBounds = annotation.bounds
        let originalColor = annotation.color
        // Hide the annotation while the editor is open
        annotation.color = .clear

        let pagePoint = CGPoint(x: originalBounds.minX, y: originalBounds.midY)
        showInlineComment(at: pagePoint, on: page, initialText: annotation.contents ?? "",
        onCommit: { [weak self] text in
            guard let self else { return }
            let font = NSFont(name: "Helvetica", size: 10) ?? NSFont.systemFont(ofSize: 10)
            let measured = (text as NSString).boundingRect(
                with: CGSize(width: originalBounds.width - 8, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            let height = max(30, ceil(measured.height) + 12)
            annotation.contents = text
            annotation.bounds = CGRect(x: originalBounds.minX, y: originalBounds.midY - height / 2,
                                       width: originalBounds.width, height: height)
            annotation.color = originalColor
            self.annotationDelegate?.pdfViewDidModify(self)
        },
        onCancel: {
            annotation.color = originalColor
        })
    }

    override func mouseDown(with event: NSEvent) {
        let hadEditor = inlineEditorContainer != nil
        // Always claim focus — if an inline editor is open this causes it to resign and commit
        window?.makeFirstResponder(self)
        let loc = pageLocation(for: event)

        switch currentTool {
        case .pointer:
            let hit = loc.flatMap { loc in
                loc.page.annotations.last(where: { $0.bounds.standardized.insetBy(dx: -2, dy: -2).contains(loc.point) })
            }
            // Double-click on a user text annotation → edit it
            if event.clickCount == 2, let ann = hit, let hitLoc = loc,
               ann.userName?.hasPrefix("grader.") != true, ann.font != nil {
                selectAnnotation(nil)
                editTextAnnotation(ann, on: hitLoc.page)
                return
            }
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
            if let loc, let hit = loc.page.annotations.last(where: { $0.bounds.standardized.insetBy(dx: -4, dy: -4).contains(loc.point) }) {
                selectAnnotation(nil)
                annotationDelegate?.removeAnnotationWithUndo(hit)
            }

        case .grade:
            if let loc {
                annotationDelegate?.pdfViewHandleGradeClick(at: loc.point, on: loc.page)
            }

        case .highlight:
            guard let loc else { return }
            highlightDragPage = loc.page
            highlightDragStartPagePoint = loc.point

        case .ink:
            guard let loc else { return }
            inkDragPage = loc.page
            inkPoints = [loc.point]
            beginInkOverlay()

        case .text:
            guard let loc else { super.mouseDown(with: event); return }
            let viewPoint = convert(event.locationInWindow, from: nil)

            // 1. A corner handle of the selected comment → begin resize (opposite corner anchors)
            if let sel = commentSelection, let corner = handleCorner(at: viewPoint) {
                resizeAnchorPagePoint = corner.opposite.point(in: sel.bounds)
                resizeOriginalBounds = sel.bounds
                resizingAnnotation = sel
                return
            }

            // 2. An existing comment under the click
            if let hit = loc.page.annotations.last(where: { isEditableComment($0) && $0.bounds.contains(loc.point) }) {
                if event.clickCount == 2 {
                    selectAnnotation(nil)
                    editTextAnnotation(hit, on: loc.page)  // double-click → edit
                    return
                }
                // Single-click → select (show handles) and begin move
                selectAnnotation(hit, handles: true)
                draggingAnnotation = hit
                dragStartPagePoint = loc.point
                dragOriginalOrigin = hit.bounds.origin
                return
            }

            // 3. Empty area: deselect if something is selected, otherwise create a new comment
            if commentSelection != nil {
                selectAnnotation(nil)
                return
            }
            // If this click just dismissed an inline editor, don't also create a new comment
            if hadEditor { return }
            annotationDelegate?.pdfView(self, didClickAt: loc.point, on: loc.page, tool: currentTool)

        case .stamp:
            guard let loc else { super.mouseDown(with: event); return }
            annotationDelegate?.pdfView(self, didClickAt: loc.point, on: loc.page, tool: currentTool)
        }
    }

    // Right-click → Delete works regardless of current tool
    // Summary transparency state is encoded in the userName (a PDF /T string that persists,
    // unlike the background-color alpha which the PDF /C entry cannot store).
    static let summaryTag = "grader.summary"
    static let summaryTranslucentTag = "grader.summary.translucent"

    override func menu(for event: NSEvent) -> NSMenu? {
        if let loc = pageLocation(for: event),
           let annotation = loc.page.annotations.last(where: { $0.bounds.contains(loc.point) }) {
            selectAnnotation(annotation)
            let menu = NSMenu()

            // Summaries get a transparency toggle
            if let name = annotation.userName, name.hasPrefix(Self.summaryTag) {
                let isTranslucent = (name == Self.summaryTranslucentTag)
                let toggle = NSMenuItem(title: isTranslucent ? "Make Summary Opaque" : "Make Summary Transparent",
                                        action: #selector(toggleSummaryTransparency), keyEquivalent: "")
                toggle.target = self
                menu.addItem(toggle)
                menu.addItem(.separator())
            }

            let item = NSMenuItem(title: "Delete Annotation",
                                  action: #selector(deleteSelected), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return menu
        }
        return super.menu(for: event)
    }

    @objc private func toggleSummaryTransparency() {
        guard let annotation = selectedAnnotation,
              let name = annotation.userName, name.hasPrefix(Self.summaryTag) else { return }
        setSummaryTransparency(annotation, translucent: name != Self.summaryTranslucentTag)
    }

    /// Applies a transparency state to a summary annotation, registers the inverse toggle for
    /// undo/redo, and persists. State is stored in the userName so it survives save/reload.
    private func setSummaryTransparency(_ annotation: PDFAnnotation, translucent: Bool) {
        let yellow = NSColor(red: 1.0, green: 251/255, blue: 179/255, alpha: translucent ? 0.5 : 1.0)
        annotation.userName = translucent ? Self.summaryTranslucentTag : Self.summaryTag
        if selectedAnnotation === annotation {
            // Keep the restore-color in sync and drop the blue selection tint to reveal the change.
            selectedOriginalColor = yellow
            selectAnnotation(nil)
        } else {
            annotation.color = yellow
        }
        undoManager?.registerUndo(withTarget: self) { view in
            view.setSummaryTransparency(annotation, translucent: !translucent)
        }
        undoManager?.setActionName("Toggle Summary Transparency")
        annotationDelegate?.pdfViewDidModify(self)  // persist
    }

    @objc private func deleteSelected() {
        guard let annotation = selectedAnnotation else { return }
        selectAnnotation(nil)
        annotationDelegate?.removeAnnotationWithUndo(annotation)
    }

    /// Selects `annotation`. With `handles: false` (pointer / right-click) the annotation is
    /// tinted blue. With `handles: true` (Comment tool) the real color is kept and four corner
    /// resize handles are shown instead. Passing nil clears any selection and the handles.
    func selectAnnotation(_ annotation: PDFAnnotation?, handles: Bool = false) {
        // Restore previous selection's original color
        if let prev = selectedAnnotation, let orig = selectedOriginalColor {
            prev.color = orig
        }
        selectedAnnotation = annotation
        selectedOriginalColor = annotation?.color
        selectionTinted = false

        if let annotation, handles {
            commentSelection = annotation
            commentSelectionPage = annotation.page
            showCommentHandles()
            positionCommentHandles()
        } else {
            commentSelection = nil
            commentSelectionPage = nil
            hideCommentHandles()
            if let annotation {
                // Blue tint to signal selection; semi-transparent so content stays readable
                annotation.color = NSColor.systemBlue.withAlphaComponent(0.25)
                selectionTinted = true
            }
        }
    }

    // MARK: - Comment selection handles

    private func isEditableComment(_ ann: PDFAnnotation) -> Bool {
        guard let t = ann.type, t.hasSuffix("FreeText") else { return false }
        return ann.userName?.hasPrefix("grader.") != true && ann.font != nil
    }

    private func showCommentHandles() {
        if commentHandles == nil {
            let ov = CommentSelectionView(frame: bounds)
            ov.autoresizingMask = [.width, .height]
            addSubview(ov)
            commentHandles = ov
        }
    }

    private func hideCommentHandles() {
        commentHandles?.removeFromSuperview()
        commentHandles = nil
    }

    /// Reposition the handles overlay from the comment's current page-space bounds. Called on
    /// select, during move/resize, and on scroll/zoom so the handles stay glued to the box.
    func positionCommentHandles() {
        guard let ov = commentHandles as? CommentSelectionView,
              let ann = commentSelection, let page = commentSelectionPage else { return }
        ov.boxRect = convert(ann.bounds, from: page)
    }

    /// The resize corner under a view-space point, if a comment is selected.
    private func handleCorner(at viewPoint: CGPoint) -> HandleCorner? {
        guard let ov = commentHandles as? CommentSelectionView, commentSelection != nil else { return nil }
        for (i, r) in CommentSelectionView.handleRects(for: ov.boxRect).enumerated() where r.contains(viewPoint) {
            return HandleCorner(rawValue: i)
        }
        return nil
    }

    /// Registers a reversible bounds change (move/resize) for undo/redo.
    private func registerBoundsUndo(_ ann: PDFAnnotation, old: CGRect, name: String) {
        undoManager?.registerUndo(withTarget: self) { view in
            let current = ann.bounds
            if let page = ann.page {
                page.removeAnnotation(ann)
                ann.bounds = old
                page.addAnnotation(ann)
            } else {
                ann.bounds = old
            }
            view.registerBoundsUndo(ann, old: current, name: name)  // redo
            if view.commentSelection === ann { view.positionCommentHandles() }
            view.annotationDelegate?.pdfViewDidModify(view)
        }
        undoManager?.setActionName(name)
    }

    // MARK: - Freehand ink preview overlay

    private func beginInkOverlay() {
        endInkOverlay()
        let ov = InkOverlayView(frame: bounds)
        ov.autoresizingMask = [.width, .height]
        ov.strokeColor = PDFViewerView.Coordinator.inkColor
        ov.lineWidth = PDFViewerView.Coordinator.inkLineWidth * scaleFactor
        addSubview(ov)
        inkOverlay = ov
    }

    private func updateInkOverlay() {
        guard let ov = inkOverlay as? InkOverlayView, let page = inkDragPage else { return }
        ov.lineWidth = PDFViewerView.Coordinator.inkLineWidth * scaleFactor
        ov.points = inkPoints.map { convert($0, from: page) }
    }

    private func endInkOverlay() {
        inkOverlay?.removeFromSuperview()
        inkOverlay = nil
    }

    override func mouseDragged(with event: NSEvent) {
        // Comment resize drag — span a rect between the fixed anchor corner and the cursor
        if let ann = resizingAnnotation, let page = commentSelectionPage {
            let viewPoint = convert(event.locationInWindow, from: nil)
            var p = convert(viewPoint, to: page)
            let a = resizeAnchorPagePoint
            let minW: CGFloat = 40, minH: CGFloat = 16  // ~1.2em at the 10pt comment font
            if abs(p.x - a.x) < minW { p.x = a.x + (p.x >= a.x ? minW : -minW) }
            if abs(p.y - a.y) < minH { p.y = a.y + (p.y >= a.y ? minH : -minH) }
            ann.bounds = CGRect(x: min(a.x, p.x), y: min(a.y, p.y),
                                width: abs(p.x - a.x), height: abs(p.y - a.y))
            positionCommentHandles()
            return
        }

        // Freehand ink drag — accumulate page-space points and refresh the live preview
        if let page = inkDragPage {
            let viewPt = convert(event.locationInWindow, from: nil)
            inkPoints.append(convert(viewPt, to: page))
            updateInkOverlay()
            return
        }

        // Highlight rubber-band drag
        if let startPage = highlightDragPage, let startPt = highlightDragStartPagePoint {
            let viewPt = convert(event.locationInWindow, from: nil)
            let startViewPt = convert(startPt, from: startPage)
            let rect = NSRect(
                x: min(startViewPt.x, viewPt.x),
                y: min(startViewPt.y, viewPt.y),
                width: abs(viewPt.x - startViewPt.x),
                height: abs(viewPt.y - startViewPt.y)
            )
            if let rb = highlightRubberBand {
                rb.frame = rect
            } else {
                let rb = NSView(frame: rect)
                rb.wantsLayer = true
                rb.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0, alpha: 0.35).cgColor
                rb.layer?.borderWidth = 1
                rb.layer?.borderColor = NSColor(calibratedRed: 1, green: 0.75, blue: 0, alpha: 0.8).cgColor
                addSubview(rb)
                highlightRubberBand = rb
            }
            return
        }

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
        if ann === commentSelection { positionCommentHandles() }
    }

    override func mouseUp(with event: NSEvent) {
        // Commit freehand ink stroke
        if let page = inkDragPage {
            let viewPt = convert(event.locationInWindow, from: nil)
            inkPoints.append(convert(viewPt, to: page))
            let points = inkPoints
            endInkOverlay()
            inkDragPage = nil
            inkPoints = []
            annotationDelegate?.pdfViewDidDrawInk(points: points, on: page)
            return
        }

        // Commit highlight rectangle
        if let startPage = highlightDragPage, let startPt = highlightDragStartPagePoint {
            highlightRubberBand?.removeFromSuperview()
            highlightRubberBand = nil
            highlightDragPage = nil
            highlightDragStartPagePoint = nil
            let viewPt = convert(event.locationInWindow, from: nil)
            let endPt = convert(viewPt, to: startPage)
            let pageRect = CGRect(
                x: min(startPt.x, endPt.x),
                y: min(startPt.y, endPt.y),
                width: abs(endPt.x - startPt.x),
                height: abs(endPt.y - startPt.y)
            )
            guard pageRect.width > 4 && pageRect.height > 4 else { return }
            annotationDelegate?.pdfViewDidDrawHighlight(bounds: pageRect, on: startPage)
            return
        }

        // Commit comment resize
        if let ann = resizingAnnotation, let page = ann.page {
            let finalBounds = ann.bounds
            let oldBounds = resizeOriginalBounds
            page.removeAnnotation(ann)
            ann.bounds = finalBounds
            page.addAnnotation(ann)
            resizingAnnotation = nil
            if oldBounds != finalBounds {
                registerBoundsUndo(ann, old: oldBounds, name: "Resize Comment")
            }
            selectAnnotation(ann, handles: true)  // keep selection + handles
            annotationDelegate?.pdfViewDidModify(self)
            return
        }

        if let ann = draggingAnnotation, let page = ann.page {
            let finalBounds = ann.bounds
            let wasComment = (ann === commentSelection)
            let origin = dragOriginalOrigin
            // Commit the move: remove+re-add forces PDFKit to clear the old rendered
            // position and draw at the new one. Without this, file-loaded annotations
            // leave a ghost at their original position after a drag.
            page.removeAnnotation(ann)
            ann.bounds = finalBounds
            page.addAnnotation(ann)
            draggingAnnotation = nil
            dragStartPagePoint = nil
            dragOriginalOrigin = nil
            if wasComment {
                if let origin, origin != finalBounds.origin {
                    registerBoundsUndo(ann, old: CGRect(origin: origin, size: finalBounds.size),
                                       name: "Move Comment")
                }
                selectAnnotation(ann, handles: true)  // keep selection + handles
            } else {
                selectAnnotation(nil)
            }
            annotationDelegate?.pdfViewDidModify(self)
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

        // Annotation tool shortcuts (PDF view must have focus — won't fire in sidebar).
        // Keys are user-configurable via Settings; resolve the bound action dynamically.
        if (mods.isEmpty || mods == .shift), let ch,
           let action = ShortcutSettings.shared.action(forKey: ch) {
            switch action {
            case .pointer:   annotationDelegate?.pdfViewDidRequestTool(.pointer)
            case .comment:   annotationDelegate?.pdfViewDidRequestTool(.text)
            case .highlight: annotationDelegate?.pdfViewDidRequestTool(.highlight)
            case .handwriting: annotationDelegate?.pdfViewDidRequestTool(.ink)
            case .delete:    annotationDelegate?.pdfViewDidRequestTool(.delete)
            case .grade:     annotationDelegate?.pdfViewDidRequestTool(.grade)
            case .rotate:
                if let page = currentPage {
                    page.rotation = (page.rotation + 90) % 360
                    annotationDelegate?.pdfViewDidModify(self)
                }
            case .correct:   annotationDelegate?.pdfViewDidRequestTool(.stamp(.correct))
            case .incorrect: annotationDelegate?.pdfViewDidRequestTool(.stamp(.incorrect))
            case .partial:   annotationDelegate?.pdfViewDidRequestTool(.stamp(.partial))
            }
            return
        }

        // Escape clears a comment selection (and its handles)
        if event.keyCode == 53, commentSelection != nil {
            selectAnnotation(nil)
            return
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

    // Keep the comment handles glued to the box as the content scrolls or the zoom changes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if clipObserver == nil,
           let clip = subviews.compactMap({ $0 as? NSScrollView }).first?.contentView {
            clip.postsBoundsChangedNotifications = true
            clipObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in self?.positionCommentHandles() }
        }
        if scaleObserver == nil {
            scaleObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name.PDFViewScaleChanged, object: self, queue: .main
            ) { [weak self] _ in self?.positionCommentHandles() }
        }
    }

    deinit {
        if let o = clipObserver  { NotificationCenter.default.removeObserver(o) }
        if let o = scaleObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func pageLocation(for event: NSEvent) -> (page: PDFPage, point: CGPoint)? {
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return nil }
        return (page, convert(viewPoint, to: page))
    }
}
