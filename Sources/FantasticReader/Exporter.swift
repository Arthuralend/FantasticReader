import AppKit
import PDFKit

enum Exporter {
    /// PDF «как фото документа»: исходные изображения и PDF-файлы без изменений, одним документом.
    static func savePDF(sources: [URL], to dest: URL) throws {
        let doc = PDFDocument()
        for src in sources {
            if src.pathExtension.lowercased() == "pdf" {
                guard let pdf = PDFDocument(url: src) else { continue }
                for i in 0..<pdf.pageCount {
                    if let p = pdf.page(at: i) { doc.insert(p, at: doc.pageCount) }
                }
            } else if let image = NSImage(contentsOf: src), let page = PDFPage(image: image) {
                doc.insert(page, at: doc.pageCount)
            }
        }
        guard doc.pageCount > 0, doc.write(to: dest) else { throw GeminiError(message: "Не удалось записать PDF") }
    }

    /// DOCX только с текстом, без изображений.
    /// Понимает простую разметку из распознавания: "# " — заголовок, "> " — стих/эпиграф,
    /// пустая строка — граница абзаца.
    static func saveDOCX(text: String, to dest: URL) throws {
        let base = font(for: text, size: 12)
        let heading = NSFontManager.shared.convert(font(for: text, size: 15), toHaveTrait: .boldFontMask)
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
        let data = try out.data(from: NSRange(location: 0, length: out.length),
                                documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: dest)
    }

    /// Подбирает шрифт, в котором есть буквы нужного алфавита (армянский, грузинский, арабский и т.д.).
    private static func font(for text: String, size: CGFloat) -> NSFont {
        let base = NSFont(name: "Times New Roman", size: size) ?? NSFont.systemFont(ofSize: size)
        guard let sample = text.unicodeScalars.first(where: { $0.value > 0x24F && CharacterSet.letters.contains($0) }) else {
            return base
        }
        let s = String(sample) as CFString
        let ct = CTFontCreateForString(base as CTFont, s, CFRange(location: 0, length: CFStringGetLength(s)))
        let name = CTFontCopyFamilyName(ct) as String
        if name == "LastResort" { return base }
        return NSFont(name: CTFontCopyPostScriptName(ct) as String, size: size) ?? base
    }
}
