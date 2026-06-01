import Foundation
import CoreGraphics

enum PDFScaler {
    static let letterSize = CGSize(width: 612, height: 792) // 8.5 × 11 in at 72 dpi

    /// Rewrites `url` in-place, scaling every page to fit letter size.
    /// Pages already within 2 pts of letter on both dimensions are left untouched.
    static func scaleToLetterIfNeeded(url: URL) {
        guard let source = CGPDFDocument(url as CFURL) else { return }
        guard pageNeedsScaling(source) else { return }

        // Write scaled PDF to the system temp directory (always writable in sandbox)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grader_\(UUID().uuidString).pdf")

        var letterRect = CGRect(origin: .zero, size: letterSize)
        guard let ctx = CGContext(tempURL as CFURL, mediaBox: &letterRect, nil) else { return }

        for i in 1...source.numberOfPages {
            guard let page = source.page(at: i) else { continue }
            var box = letterRect
            ctx.beginPage(mediaBox: &box)

            let srcRect = page.getBoxRect(.mediaBox)
            let (scale, tx, ty) = fitTransform(from: srcRect.size, into: letterSize)

            ctx.saveGState()
            ctx.translateBy(x: tx, y: ty)
            ctx.scaleBy(x: scale, y: scale)
            if srcRect.origin != .zero {
                ctx.translateBy(x: -srcRect.origin.x, y: -srcRect.origin.y)
            }
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()

        // Replace original with scaled version.
        // The sandbox allows writing the user-selected file itself (user-selected.read-write).
        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private static func pageNeedsScaling(_ doc: CGPDFDocument) -> Bool {
        let tol: CGFloat = 2
        for i in 1...doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let r = page.getBoxRect(.mediaBox)
            if abs(r.width - letterSize.width) > tol || abs(r.height - letterSize.height) > tol {
                return true
            }
        }
        return false
    }

    private static func fitTransform(from src: CGSize, into dst: CGSize) -> (CGFloat, CGFloat, CGFloat) {
        let scale = min(dst.width / src.width, dst.height / src.height)
        let tx = (dst.width  - src.width  * scale) / 2
        let ty = (dst.height - src.height * scale) / 2
        return (scale, tx, ty)
    }
}
