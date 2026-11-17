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
    static func saveDOCX(text: String, to dest: URL) throws {
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)])
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: dest)
    }
}
