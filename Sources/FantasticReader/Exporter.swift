import AppKit
import PDFKit

enum Exporter {
    /// PDF «как фото документа»: исходное изображение (или исходный PDF) без изменений.
    static func savePDF(source: URL, to dest: URL) throws {
        if source.pathExtension.lowercased() == "pdf" {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: source, to: dest)
            return
        }
        guard let image = NSImage(contentsOf: source), let page = PDFPage(image: image) else {
            throw GeminiError(message: "Не удалось открыть изображение")
        }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        guard doc.write(to: dest) else { throw GeminiError(message: "Не удалось записать PDF") }
    }

    /// DOCX только с текстом, без изображений.
    static func saveDOCX(text: String, to dest: URL) throws {
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)])
        let data = try attr.data(from: NSRange(location: 0, length: attr.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: dest)
    }
}
