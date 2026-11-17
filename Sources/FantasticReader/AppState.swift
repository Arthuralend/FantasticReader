import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PageItem: Identifiable {
    let id = UUID()
    let url: URL
    var thumb: NSImage?
    var text = ""
    var done = false
}

@MainActor
final class AppState: ObservableObject {
    @Published var pages: [PageItem] = []
    @Published var selection: UUID?
    @Published var busy = false
    @Published var status = "Откройте фото или PDF"
    @Published var error: String?
    @Published var zoom: Double = 1.0
    @Published var apiKey = Keychain.load() ?? ""
    @Published var model = UserDefaults.standard.string(forKey: "model") ?? GeminiClient.defaultModel
    @Published var showSettings = false

    var selectedIndex: Int? { pages.firstIndex { $0.id == selection } }

    func saveSettings() {
        Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        model = m.isEmpty ? GeminiClient.defaultModel : m
        UserDefaults.standard.set(model, forKey: "model")
    }

    func add(urls: [URL]) {
        for u in urls {
            _ = u.startAccessingSecurityScopedResource()
            let isPDF = u.pathExtension.lowercased() == "pdf"
            let img: NSImage? = isPDF
                ? PDFDocument(url: u)?.page(at: 0)?.thumbnail(of: CGSize(width: 1600, height: 2200), for: .mediaBox)
                : NSImage(contentsOf: u)
            pages.append(PageItem(url: u, thumb: img))
        }
        if selection == nil { selection = pages.first?.id }
        status = "Страниц: \(pages.count)"
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
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { showSettings = true; return }
        busy = true; error = nil
        defer { busy = false }
        do { try await work(); status = "Готово" }
        catch { self.error = error.localizedDescription; status = "Ошибка" }
    }

    private func recognize(index i: Int) async throws {
        status = "Распознавание: страница \(i + 1) из \(pages.count)…"
        let url = pages[i].url
        let data = try Data(contentsOf: url)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
        let client = GeminiClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), model: model)
        let text = try await client.recognize(data: data, mimeType: mime)
        guard pages.indices.contains(i) else { return }
        pages[i].text = text
        pages[i].done = true
    }

    func save(pdf: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : UTType("org.openxmlformats.wordprocessingml.document")!]
        panel.nameFieldStringValue = (pages.first?.url.deletingPathExtension().lastPathComponent ?? "FantasticReader") + (pdf ? ".pdf" : ".docx")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if pdf { try Exporter.savePDF(sources: pages.map(\.url), to: dest) }
            else { try Exporter.saveDOCX(text: pages.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), to: dest) }
            status = "Сохранено: \(dest.lastPathComponent)"
        } catch { self.error = error.localizedDescription }
    }
}
