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

    /// Rewrites `url` in-place, baking any page rotation into the content and clearing the flag.
    /// Scanners (e.g. Xerox) embed a rotation flag that Preview honors but PDFKit ignores during
    /// annotation placement, causing stamps to land in the wrong position.
    static func fixRotationIfNeeded(url: URL) {
        guard let source = CGPDFDocument(url as CFURL) else { return }
        guard (1...source.numberOfPages).contains(where: { source.page(at: $0).map { $0.rotationAngle != 0 } ?? false }) else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grader_rot_\(UUID().uuidString).pdf")

        // Pass nil mediaBox so we set it per-page
        guard let ctx = CGContext(tempURL as CFURL, mediaBox: nil, nil) else { return }

        for i in 1...source.numberOfPages {
            guard let page = source.page(at: i) else { continue }
            let rotation = page.rotationAngle  // degrees CW (CGPDFPage convention)
            let srcBox = page.getBoxRect(.mediaBox)

            // Display size after rotation
            let swapAxes = (rotation == 90 || rotation == 270)
            let displaySize = swapAxes
                ? CGSize(width: srcBox.height, height: srcBox.width)
                : srcBox.size
            var pageRect = CGRect(origin: .zero, size: displaySize)

            ctx.beginPage(mediaBox: &pageRect)
            ctx.saveGState()

            // Un-rotate: bake the rotation into the content
            switch rotation {
            case 90:   // CGPDFPage CW 90° = CCW 270° display
                ctx.translateBy(x: 0, y: srcBox.width)
                ctx.rotate(by: -CGFloat.pi / 2)
            case 180:
                ctx.translateBy(x: srcBox.width, y: srcBox.height)
                ctx.rotate(by: CGFloat.pi)
            case 270:  // CGPDFPage CW 270° = CCW 90° display
                ctx.translateBy(x: srcBox.height, y: 0)
                ctx.rotate(by: CGFloat.pi / 2)
            default:
                break
            }

            if srcBox.origin != .zero {
                ctx.translateBy(x: -srcBox.origin.x, y: -srcBox.origin.y)
            }
            ctx.drawPDFPage(page)
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()

        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Rewrites `url` in-place, rasterizing any page that contains "vector ink" (iPad
    /// handwriting drawn through a transparency-group Form XObject) to a flat 300-DPI image.
    ///
    /// PDFKit flattens ("bakes") FreeText annotations into the page content stream when it
    /// serializes a document whose pages contain this vector-ink layer — making grading
    /// comments/stamps opaque, immovable and undeletable. Rasterizing the ink dissolves the
    /// trigger (the page becomes a plain image, like a scanned submission, which never bakes)
    /// while leaving the page visually identical. Scanned and typed PDFs carry no such layer
    /// and are left completely untouched.
    static let rasterDPI: CGFloat = 300

    static func rasterizeInkIfNeeded(url: URL) {
        guard let source = CGPDFDocument(url as CFURL) else { return }
        let pagesToRasterize = (1...source.numberOfPages).filter { i in
            source.page(at: i).map(pageHasTransparencyGroupForm) ?? false
        }
        guard !pagesToRasterize.isEmpty else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grader_raster_\(UUID().uuidString).pdf")
        guard let ctx = CGContext(tempURL as CFURL, mediaBox: nil, nil) else { return }

        let toRaster = Set(pagesToRasterize)
        for i in 1...source.numberOfPages {
            guard let page = source.page(at: i) else { continue }
            var box = page.getBoxRect(.mediaBox)
            ctx.beginPage(mediaBox: &box)
            if toRaster.contains(i) {
                drawPageRasterized(page, into: ctx, box: box, dpi: rasterDPI)
            } else {
                ctx.drawPDFPage(page)
            }
            ctx.endPage()
        }
        ctx.closePDF()

        do {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tempURL, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    /// Renders `page` to an offscreen bitmap at `dpi` and draws it into `ctx` filling `box`.
    private static func drawPageRasterized(_ page: CGPDFPage, into ctx: CGContext, box: CGRect, dpi: CGFloat) {
        let scale = dpi / 72.0
        let pxW = Int((box.width * scale).rounded()), pxH = Int((box.height * scale).rounded())
        let cs = CGColorSpaceCreateDeviceRGB()
        guard pxW > 0, pxH > 0,
              let bmp = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            ctx.drawPDFPage(page)  // fall back to a vector copy on failure
            return
        }
        bmp.setFillColor(CGColor(gray: 1, alpha: 1))
        bmp.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))
        bmp.scaleBy(x: scale, y: scale)
        if box.origin != .zero { bmp.translateBy(x: -box.origin.x, y: -box.origin.y) }
        bmp.drawPDFPage(page)
        guard let img = bmp.makeImage() else { ctx.drawPDFPage(page); return }
        ctx.draw(img, in: box)
    }

    /// True if any XObject in the page's resources (recursively) is a Form with a
    /// transparency group — the signature of iPad handwriting-ink layers.
    private static func pageHasTransparencyGroupForm(_ page: CGPDFPage) -> Bool {
        guard let dict = page.dictionary else { return false }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources), let resources else { return false }
        return dictionaryHasTransparencyGroupForm(resources, depth: 0)
    }

    private static func dictionaryHasTransparencyGroupForm(_ resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(xobjects, { _, value, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(value, .stream, &stream), let stream,
                  let sdict = CGPDFStreamGetDictionary(stream) else { return true }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(sdict, "Subtype", &subtype), let subtype,
                  String(cString: subtype) == "Form" else { return true }
            // Direct transparency group?
            var group: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(sdict, "Group", &group), let group {
                var s: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(group, "S", &s), let s, String(cString: s) == "Transparency" {
                    found = true
                    return false  // stop iterating
                }
            }
            // Otherwise recurse into the form's own resources
            var fres: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(sdict, "Resources", &fres), let fres,
               dictionaryHasTransparencyGroupForm(fres, depth: depth + 1) {
                found = true
                return false
            }
            return true
        }, nil)
        return found
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
