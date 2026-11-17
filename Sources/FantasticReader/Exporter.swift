import AppKit
import PDFKit
import CoreText

enum Exporter {
    // MARK: - PDF

    static func savePDF(pages: [PageItem], mode: PDFMode, family: String, size: CGFloat, to dest: URL) throws {
        if mode == .text {
            let text = pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !text.isEmpty else { throw GeminiError(message: "Нет распознанного текста") }
            try saveTextPDF(attributed(text: text, family: family, size: size), to: dest)
            return
        }

        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { throw GeminiError(message: "Не удалось создать PDF") }
        var docs: [URL: PDFDocument] = [:]
        var count = 0

        for p in pages {
            let rect: CGRect
            if let idx = p.pageIndex {
                if docs[p.url] == nil { docs[p.url] = PDFDocument(url: p.url) }
                guard let page = docs[p.url]?.page(at: idx) else { continue }
                var sz = page.bounds(for: .mediaBox).size
                if page.rotation % 180 != 0 { sz = CGSize(width: sz.height, height: sz.width) }
                rect = CGRect(origin: .zero, size: sz)
                beginPage(ctx, rect)
                page.draw(with: .mediaBox, to: ctx)
            } else {
                guard let img = NSImage(contentsOf: p.url) else { continue }
                rect = CGRect(origin: .zero, size: img.size)
                beginPage(ctx, rect)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
                img.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            }
            if mode == .imageText { drawTextLayer(ctx, page: p, rect: rect, family: family) }
            ctx.endPDFPage()
            count += 1
        }
        ctx.closePDF()
        if count == 0 { throw GeminiError(message: "Нет страниц для сохранения") }
    }

    private static func beginPage(_ ctx: CGContext, _ rect: CGRect) {
        var r = rect
        let data = NSData(bytes: &r, length: MemoryLayout<CGRect>.size)
        ctx.beginPDFPage([kCGPDFContextMediaBox as String: data] as CFDictionary)
    }

    /// Невидимый текст поверх изображения: PDF можно искать, выделять и копировать.
    private static func drawTextLayer(_ ctx: CGContext, page p: PageItem, rect: CGRect, family: String) {
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        if !p.lines.isEmpty {
            // Apple Vision знает положение каждой строки — текст ложится точно на неё.
            for l in p.lines {
                let b = CGRect(x: rect.minX + l.rect.minX * rect.width, y: rect.minY + l.rect.minY * rect.height,
                               width: l.rect.width * rect.width, height: l.rect.height * rect.height)
                guard b.width > 1, b.height > 1 else { continue }
                let f = font(for: l.text, size: b.height * 0.8, family: family)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: l.text, attributes: [.font: f]))
                let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                guard w > 0 else { continue }
                ctx.saveGState()
                ctx.translateBy(x: b.minX, y: b.minY + b.height * 0.2)
                ctx.scaleBy(x: b.width / w, y: 1)
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            }
        } else if !p.text.isEmpty {
            // Gemini не даёт координат: текст распределяется по всей странице.
            let plain = stripMarkup(p.text)
            let area = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.05)
            var size: CGFloat = 14
            while true {
                let attr = NSAttributedString(string: plain, attributes: [.font: font(for: plain, size: size, family: family)])
                let fs = CTFramesetterCreateWithAttributedString(attr)
                let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: area, transform: nil), nil)
                if CTFrameGetVisibleStringRange(frame).length >= attr.length || size <= 3 {
                    CTFrameDraw(frame, ctx); break
                }
                size -= 1
            }
        }
        ctx.restoreGState()
    }

    /// Только текст: страницы A4, оформление как в DOCX.
    private static func saveTextPDF(_ attr: NSAttributedString, to dest: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        var box = page
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { throw GeminiError(message: "Не удалось создать PDF") }
        let fs = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: page.insetBy(dx: 56, dy: 56), transform: nil)
        var pos = 0
        repeat {
            beginPage(ctx, page)
            let frame = CTFramesetterCreateFrame(fs, CFRange(location: pos, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame).length
            if visible == 0 { break }
            pos += visible
        } while pos < attr.length
        ctx.closePDF()
    }

    private static func stripMarkup(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return t.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix(">") { return String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return t
        }.joined(separator: "\n")
    }

    // MARK: - DOCX

    /// DOCX только с текстом, без изображений.
    static func saveDOCX(text: String, family: String, size: CGFloat, to dest: URL) throws {
        let out = attributed(text: text, family: family, size: size)
        let data = try out.data(from: NSRange(location: 0, length: out.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: dest)
    }

    /// Оформленный текст. Разметка распознавания: "# " — заголовок, "> " — стих/эпиграф,
    /// пустая строка — граница абзаца.
    static func attributed(text: String, family: String, size: CGFloat) -> NSAttributedString {
        let base = font(for: text, size: size, family: family)
        let heading = NSFontManager.shared.convert(font(for: text, size: size * 1.25, family: family), toHaveTrait: .boldFontMask)
        let verse = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)

        let body = NSMutableParagraphStyle()
        body.alignment = .justified
        body.firstLineHeadIndent = 28
        body.paragraphSpacing = 6
        body.lineHeightMultiple = 1.15

        let head = NSMutableParagraphStyle()
        head.alignment = .center
        head.paragraphSpacing = 14
        head.paragraphSpacingBefore = 6

        let poem = NSMutableParagraphStyle()
        poem.alignment = .left
        poem.firstLineHeadIndent = 220
        poem.headIndent = 220
        poem.paragraphSpacing = 0

        let out = NSMutableAttributedString()
        var prevWasVerse = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            var str = line
            var attrs: [NSAttributedString.Key: Any]
            if line.hasPrefix("#") {
                str = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                attrs = [.font: heading, .paragraphStyle: head]
                prevWasVerse = false
            } else if line.hasPrefix(">") {
                str = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let ps = poem.mutableCopy() as! NSMutableParagraphStyle
                if !prevWasVerse { ps.paragraphSpacingBefore = 10 }
                attrs = [.font: verse, .paragraphStyle: ps]
                prevWasVerse = true
            } else {
                let ps = body.mutableCopy() as! NSMutableParagraphStyle
                if prevWasVerse { ps.paragraphSpacingBefore = 14 }
                attrs = [.font: base, .paragraphStyle: ps]
                prevWasVerse = false
            }
            out.append(NSAttributedString(string: str + "\n", attributes: attrs))
        }
        return out
    }

    /// Выбранный шрифт, а если не выбран — шрифт, в котором есть буквы нужного алфавита.
    static func font(for text: String, size: CGFloat, family: String) -> NSFont {
        if !family.isEmpty, let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return f
        }
        let base = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        guard let sample = text.unicodeScalars.first(where: { $0.value > 0x24F && CharacterSet.letters.contains($0) }) else {
            return base
        }
        let s = String(sample) as CFString
        let ct = CTFontCreateForString(base as CTFont, s, CFRange(location: 0, length: CFStringGetLength(s)))
        if (CTFontCopyFamilyName(ct) as String) == "LastResort" { return base }
        return NSFont(name: CTFontCopyPostScriptName(ct) as String, size: size) ?? base
    }
}
