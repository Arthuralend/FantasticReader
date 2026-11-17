import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Строка текста с положением на странице (0…1, начало снизу слева) — для текстового слоя PDF.
struct OCRLine {
    let text: String
    let rect: CGRect
}

/// Одна страница: фото или конкретная страница PDF-файла.
struct PageItem: Identifiable {
    let id = UUID()
    let url: URL
    let pageIndex: Int?          // nil — фото; число — номер страницы в PDF
    var thumb: NSImage?
    var text = ""
    var done = false
    var lines: [OCRLine] = []

    var label: String {
        pageIndex.map { "\(url.deletingPathExtension().lastPathComponent) · стр. \($0 + 1)" } ?? url.lastPathComponent
    }
}

enum PDFMode: String, CaseIterable, Identifiable {
    case image, imageText, text
    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: return "Только изображение (как скан)"
        case .imageText: return "Изображение + текстовый слой (поиск и копирование)"
        case .text: return "Только текст выбранным шрифтом"
        }
    }
}

enum OCREngine: String, CaseIterable, Identifiable {
    case gemini, apple, tesseract, cloudVision
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gemini: return "Gemini"
        case .apple: return "Apple Vision"
        case .tesseract: return "Tesseract"
        case .cloudVision: return "Cloud Vision"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var pages: [PageItem] = []
    @Published var selection: UUID? { didSet { updatePreview() } }
    @Published var preview: NSImage?
    @Published var busy = false
    @Published var status = "Откройте фото или PDF"
    @Published var error: String?
    @Published var zoom: Double = 1.0
    @Published var apiKey = Keychain.load() ?? ""
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? GeminiClient.defaultModel
    @Published var showSettings = false
    @Published var engine = OCREngine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .gemini {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "engine") }
    }
    @Published var pdfMode = PDFMode(rawValue: UserDefaults.standard.string(forKey: "pdfMode") ?? "") ?? .imageText {
        didSet { UserDefaults.standard.set(pdfMode.rawValue, forKey: "pdfMode") }
    }
    /// Пустая строка — шрифт подбирается автоматически под алфавит текста.
    @Published var fontFamily = UserDefaults.standard.string(forKey: "fontFamily") ?? "" {
        didSet { UserDefaults.standard.set(fontFamily, forKey: "fontFamily") }
    }
    @Published var fontSize = (UserDefaults.standard.object(forKey: "fontSize") as? Double) ?? 12 {
        didSet { UserDefaults.standard.set(fontSize, forKey: "fontSize") }
    }
    @Published var tessLanguages = UserDefaults.standard.stringArray(forKey: "tessLanguages") ?? [] {
        didSet { UserDefaults.standard.set(tessLanguages, forKey: "tessLanguages") }
    }
    @Published var tessBest = UserDefaults.standard.bool(forKey: "tessBest") {
        didSet { UserDefaults.standard.set(tessBest, forKey: "tessBest") }
    }
    @Published var visionKey = Keychain.load(account: Keychain.visionAccount) ?? ""
    /// Подсказки языков для Cloud Vision, напр. "hy, ru". Пусто — автоопределение.
    @Published var visionHints = UserDefaults.standard.string(forKey: "visionHints") ?? "" {
        didSet { UserDefaults.standard.set(visionHints, forKey: "visionHints") }
    }
    @Published var availableModels: [ModelInfo] = []
    @Published var modelsStatus: String?

    func loadModels() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { modelsStatus = "Сначала введите ключ"; return }
        modelsStatus = "Загрузка…"
        do {
            availableModels = try await GeminiClient.listModels(apiKey: key)
            modelsStatus = "Найдено моделей: \(availableModels.count)"
        } catch { modelsStatus = error.localizedDescription }
    }

    var selectedIndex: Int? { pages.firstIndex { $0.id == selection } }

    func saveSettings() {
        Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        Keychain.save(visionKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.visionAccount)
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        model = m.isEmpty ? GeminiClient.defaultModel : m
        UserDefaults.standard.set(model, forKey: "model")
    }

    func add(urls: [URL]) {
        for u in urls {
            _ = u.startAccessingSecurityScopedResource()
            if u.pathExtension.lowercased() == "pdf" {
                guard let doc = PDFDocument(url: u) else { error = "Не удалось открыть \(u.lastPathComponent)"; continue }
                for i in 0..<doc.pageCount {
                    let t = doc.page(at: i)?.thumbnail(of: CGSize(width: 300, height: 420), for: .mediaBox)
                    pages.append(PageItem(url: u, pageIndex: i, thumb: t))
                }
            } else {
                pages.append(PageItem(url: u, pageIndex: nil, thumb: NSImage(contentsOf: u)))
            }
        }
        if selection == nil { selection = pages.first?.id }
        status = "Страниц: \(pages.count)"
    }

    /// Крупное изображение выбранной страницы для центральной панели.
    private func updatePreview() {
        guard let i = selectedIndex else { preview = nil; return }
        let p = pages[i]
        if let idx = p.pageIndex {
            preview = PDFDocument(url: p.url)?.page(at: idx)?.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
        } else {
            preview = p.thumb
        }
    }

    func remove(_ id: UUID) {
        pages.removeAll { $0.id == id }
        if selection == id { selection = pages.first?.id }
        status = "Страниц: \(pages.count)"
    }

    func recognizeSelected() async {
        guard let i = selectedIndex else { return }
        await run { try await self.recognize(index: i) }
    }

    func recognizeAll() async {
        await run {
            for i in self.pages.indices where !self.pages[i].done {
                self.selection = self.pages[i].id
                try await self.recognize(index: i)
            }
        }
    }

    private func run(_ work: () async throws -> Void) async {
        if engine == .gemini && apiKey.trimmingCharacters(in: .whitespaces).isEmpty { showSettings = true; return }
        if engine == .cloudVision && visionKey.trimmingCharacters(in: .whitespaces).isEmpty { showSettings = true; return }
        busy = true; error = nil
        defer { busy = false }
        do { try await work(); status = "Готово" }
        catch { self.error = error.localizedDescription; status = "Ошибка" }
    }

    private func recognize(index i: Int) async throws {
        status = "Распознавание: страница \(i + 1) из \(pages.count)…"
        let item = pages[i]
        var text = ""
        var lines: [OCRLine] = []
        if engine == .apple {
            let r = try await AppleOCR.recognize(url: item.url, pageIndex: item.pageIndex)
            text = r.text; lines = r.lines
            if text.isEmpty { throw GeminiError(message: "Apple Vision не нашёл текст") }
        } else if engine == .cloudVision {
            let hints = visionHints.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "+" }).map(String.init)
            let r = try await CloudVision.recognize(url: item.url, pageIndex: item.pageIndex,
                                                    apiKey: visionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                    languageHints: hints)
            text = r.text; lines = r.lines
            if text.isEmpty { throw GeminiError(message: "Cloud Vision не нашёл текст") }
        } else if engine == .tesseract {
            let r = try await Tesseract.recognize(url: item.url, pageIndex: item.pageIndex, languages: tessLanguages)
            text = r.text; lines = r.lines
            if text.isEmpty { throw GeminiError(message: "Tesseract не нашёл текст") }
        } else {
            let (data, mime) = try payload(item)
            let client = GeminiClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
            text = try await client.recognize(data: data, mimeType: mime)
        }
        guard let j = pages.firstIndex(where: { $0.id == item.id }) else { return }
        pages[j].text = text
        pages[j].lines = lines
        pages[j].done = true
    }

    /// Данные для Gemini: фото как есть, страница PDF — отдельным одностраничным PDF.
    private func payload(_ item: PageItem) throws -> (Data, String) {
        if let idx = item.pageIndex {
            guard let page = PDFDocument(url: item.url)?.page(at: idx)?.copy() as? PDFPage else {
                throw GeminiError(message: "Не удалось прочитать страницу PDF")
            }
            let single = PDFDocument()
            single.insert(page, at: 0)
            guard let d = single.dataRepresentation() else { throw GeminiError(message: "Не удалось подготовить страницу") }
            return (d, "application/pdf")
        }
        let mime = UTType(filenameExtension: item.url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        return (try Data(contentsOf: item.url), mime)
    }

    private var baseName: String { pages.first?.url.deletingPathExtension().lastPathComponent ?? "FantasticReader" }
    private var allText: String { pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }

    func savePDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = baseName + ".pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try Exporter.savePDF(pages: pages, mode: pdfMode, family: fontFamily, size: CGFloat(fontSize), to: dest)
            status = "Сохранено: \(dest.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }

    func saveDOCX() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType("org.openxmlformats.wordprocessingml.document")!]
        panel.nameFieldStringValue = baseName + ".docx"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try Exporter.saveDOCX(text: allText, family: fontFamily, size: CGFloat(fontSize), to: dest)
            status = "Сохранено: \(dest.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
}
