import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Строка текста с положением на странице (0…1, начало снизу слева).
struct OCRLine {
    let text: String
    let rect: CGRect
    var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
}

/// Область распознавания (зелёная рамка, как в FineReader). Координаты 0…1, начало снизу слева.
struct Region: Identifiable {
    let id = UUID()
    var rect: CGRect
    /// Область нарисована/расширена туда, где строки ещё не распознаны.
    var needsOCR = false
}

/// Одна страница: фото или конкретная страница PDF-файла.
struct PageItem: Identifiable {
    let id = UUID()
    let url: URL
    let pageIndex: Int?          // nil — фото; число — номер страницы в PDF
    var thumb: NSImage?
    var text = ""
    var done = false
    var lines: [OCRLine] = []    // все найденные строки
    var regions: [Region] = []

    var label: String {
        pageIndex.map { "\(url.deletingPathExtension().lastPathComponent) · стр. \($0 + 1)" } ?? url.lastPathComponent
    }

    /// Строки, попавшие в области. Удалённые/обрезанные области убирают «мусор».
    var visibleLines: [OCRLine] {
        lines.filter { l in regions.contains { $0.rect.contains(l.center) } }
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
    case cloudVision, apple, tesseract
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cloudVision: return "Google Cloud Vision"
        case .apple: return "Apple Vision"
        case .tesseract: return "Tesseract"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var pages: [PageItem] = []
    @Published var selection: UUID? { didSet { selectedRegion = nil; drawMode = false; updatePreview() } }
    @Published var preview: NSImage?
    @Published var busy = false
    @Published var status = "Откройте фото или PDF"
    @Published var error: String?
    @Published var zoom: Double = 1.0
    @Published var showSettings = false

    // Области
    @Published var selectedRegion: UUID?
    @Published var drawMode = false
    @Published var showRegions = true

    @Published var engine = OCREngine(rawValue: UserDefaults.standard.string(forKey: "engine") ?? "") ?? .cloudVision {
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
    /// Подсказки языков для Google Cloud Vision, напр. "hy, ru". Пусто — автоопределение.
    @Published var visionHints = UserDefaults.standard.string(forKey: "visionHints") ?? "" {
        didSet { UserDefaults.standard.set(visionHints, forKey: "visionHints") }
    }

    var selectedIndex: Int? { pages.firstIndex { $0.id == selection } }
    var hasPendingRegions: Bool { selectedIndex.map { pages[$0].regions.contains { $0.needsOCR } } ?? false }

    func saveSettings() {
        Keychain.save(visionKey.trimmingCharacters(in: .whitespacesAndNewlines), account: Keychain.visionAccount)
    }

    // MARK: - Страницы

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

    // MARK: - Распознавание

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
        if engine == .cloudVision && visionKey.trimmingCharacters(in: .whitespaces).isEmpty { showSettings = true; return }
        busy = true; error = nil
        defer { busy = false }
        do { try await work(); status = "Готово" }
        catch { self.error = error.localizedDescription; status = "Ошибка" }
    }

    private func pageImage(_ item: PageItem) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try Tesseract.orientedImage(url: item.url, pageIndex: item.pageIndex)
        }.value
    }

    /// Распознать изображение выбранным движком. Координаты строк — относительно этого изображения.
    private func ocr(_ image: CGImage) async throws -> [OCRLine] {
        switch engine {
        case .apple:
            return try await AppleOCR.recognize(cgImage: image).lines
        case .tesseract:
            return try await Tesseract.recognize(cgImage: image, languages: tessLanguages).lines
        case .cloudVision:
            let hints = visionHints.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "+" }).map(String.init)
            return try await CloudVision.recognize(cgImage: image,
                                                   apiKey: visionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   languageHints: hints).lines
        }
    }

    private func recognize(index i: Int) async throws {
        status = "Распознавание: страница \(i + 1) из \(pages.count)…"
        let item = pages[i]
        let lines = try await ocr(try await pageImage(item))
        if lines.isEmpty { throw OCRError(message: "\(engine.title) не нашёл текст") }
        guard let j = pages.firstIndex(where: { $0.id == item.id }) else { return }
        pages[j].lines = lines
        pages[j].regions = Self.blocks(from: lines).map { Region(rect: $0) }
        pages[j].done = true
        recomputeText(j)
    }

    /// Текст страницы = строки внутри областей, собранные в абзацы.
    private func recomputeText(_ i: Int) {
        let visible = pages[i].visibleLines.map {
            AppleOCR.Line(text: $0.text, minX: $0.rect.minX, maxX: $0.rect.maxX, midY: $0.rect.midY, h: $0.rect.height)
        }
        pages[i].text = visible.isEmpty ? "" : AppleOCR.layout(lines: visible).text
    }

    /// Группировка строк в блоки: соседние по вертикали и перекрывающиеся по горизонтали.
    static func blocks(from lines: [OCRLine]) -> [CGRect] {
        var blocks: [CGRect] = []
        for l in lines.sorted(by: { $0.rect.maxY > $1.rect.maxY }) {
            let r = l.rect
            if let k = blocks.lastIndex(where: { b in
                let gap = b.minY - r.maxY
                let overlap = min(b.maxX, r.maxX) - max(b.minX, r.minX)
                return gap < r.height * 1.6 && gap > -r.height && overlap > 0
            }) {
                blocks[k] = blocks[k].union(r)
            } else {
                blocks.append(r)
            }
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return blocks.map { $0.insetBy(dx: -0.006, dy: -0.004).intersection(unit) }
    }

    // MARK: - Области

    func updateRegion(_ id: UUID, rect: CGRect) {
        guard let i = selectedIndex, let j = pages[i].regions.firstIndex(where: { $0.id == id }) else { return }
        let r = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.01, r.height > 0.005 else { return }
        pages[i].regions[j].rect = r
    }

    /// Вызывается, когда пользователь отпустил мышь: пересобрать текст.
    func commitRegion(_ id: UUID) {
        guard let i = selectedIndex, let j = pages[i].regions.firstIndex(where: { $0.id == id }) else { return }
        if !pages[i].done { pages[i].regions[j].needsOCR = true }
        recomputeText(i)
    }

    func addRegion(_ rect: CGRect) {
        guard let i = selectedIndex else { return }
        let r = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !r.isNull, r.width > 0.01, r.height > 0.005 else { return }
        let hasLines = pages[i].lines.contains { r.contains($0.center) }
        let region = Region(rect: r, needsOCR: !hasLines)
        pages[i].regions.append(region)
        selectedRegion = region.id
        recomputeText(i)
    }

    func deleteRegion(_ id: UUID) {
        guard let i = selectedIndex else { return }
        pages[i].regions.removeAll { $0.id == id }
        if selectedRegion == id { selectedRegion = nil }
        recomputeText(i)
    }

    func deleteSelectedRegion() { if let id = selectedRegion { deleteRegion(id) } }

    /// Распознать отмеченные оранжевым области (новые или расширенные) — только их фрагменты изображения.
    func recognizeRegions() async {
        guard let i = selectedIndex else { return }
        let pageID = pages[i].id
        await run {
            let item = self.pages[i]
            let full = try await self.pageImage(item)
            let W = CGFloat(full.width), H = CGFloat(full.height)
            for region in item.regions where region.needsOCR {
                let R = region.rect
                let px = CGRect(x: R.minX * W, y: (1 - R.maxY) * H, width: R.width * W, height: R.height * H).integral
                guard let crop = full.cropping(to: px) else { continue }
                self.status = "Распознавание области…"
                let found = try await self.ocr(crop).map { l in
                    OCRLine(text: l.text, rect: CGRect(x: R.minX + l.rect.minX * R.width, y: R.minY + l.rect.minY * R.height,
                                                       width: l.rect.width * R.width, height: l.rect.height * R.height))
                }
                guard let p = self.pages.firstIndex(where: { $0.id == pageID }) else { return }
                self.pages[p].lines.removeAll { R.contains($0.center) }
                self.pages[p].lines += found
                if let r = self.pages[p].regions.firstIndex(where: { $0.id == region.id }) {
                    self.pages[p].regions[r].needsOCR = false
                }
                self.pages[p].done = true
            }
            if let p = self.pages.firstIndex(where: { $0.id == pageID }) { self.recomputeText(p) }
        }
    }

    // MARK: - Сохранение

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
