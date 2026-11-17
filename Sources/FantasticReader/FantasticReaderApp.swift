import SwiftUI
import UniformTypeIdentifiers

@main
struct FantasticReaderApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("FantasticReader") { ContentView() }
            .defaultSize(width: 900, height: 640)
    }
}

struct ContentView: View {
    @State private var apiKey = Keychain.load() ?? ""
    @State private var fileURL: URL?
    @State private var preview: NSImage?
    @State private var text = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showImporter = false
    @State private var showKey = false

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Открыть файл…") { showImporter = true }
                Button("Распознать") { Task { await recognize() } }
                    .disabled(fileURL == nil || busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Сохранить PDF") { save(pdf: true) }.disabled(fileURL == nil)
                Button("Сохранить DOCX") { save(pdf: false) }.disabled(text.isEmpty)
                Button { showKey.toggle() } label: { Image(systemName: "key") }
                    .popover(isPresented: $showKey) { keyPanel }
            }
            HStack(spacing: 12) {
                Group {
                    if let preview {
                        Image(nsImage: preview).resizable().scaledToFit()
                    } else {
                        Text("Перетащите сюда фото или PDF").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    providers.first?.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                        if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                            DispatchQueue.main.async { load(u) }
                        }
                    }
                    return true
                }
                TextEditor(text: $text).font(.body).frame(maxWidth: .infinity)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
        }
        .padding()
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .pdf]) { r in
            if case .success(let u) = r { load(u) }
        }
        .onAppear { if apiKey.isEmpty { showKey = true } }
    }

    private var keyPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gemini API key").font(.headline)
            SecureField("AIza…", text: $apiKey).frame(width: 320)
            Text("Ключ хранится в связке ключей macOS.").font(.caption).foregroundStyle(.secondary)
            Button("Сохранить") { Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines)); showKey = false }
        }.padding()
    }

    private func load(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        fileURL = url
        error = nil
        preview = url.pathExtension.lowercased() == "pdf"
            ? PDFKitThumb.firstPage(url) : NSImage(contentsOf: url)
    }

    private func recognize() async {
        guard let url = fileURL else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { showKey = true; return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/jpeg"
            text = try await GeminiClient(apiKey: key).recognize(data: data, mimeType: mime)
        } catch { self.error = error.localizedDescription }
    }

    private func save(pdf: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [pdf ? .pdf : UTType("org.openxmlformats.wordprocessingml.document")!]
        panel.nameFieldStringValue = (fileURL?.deletingPathExtension().lastPathComponent ?? "FantasticReader") + (pdf ? ".pdf" : ".docx")
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if pdf, let src = fileURL { try Exporter.savePDF(source: src, to: dest) }
            else { try Exporter.saveDOCX(text: text, to: dest) }
        } catch { self.error = error.localizedDescription }
    }
}

import PDFKit
enum PDFKitThumb {
    static func firstPage(_ url: URL) -> NSImage? {
        PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: CGSize(width: 800, height: 1100), for: .mediaBox)
    }
}
