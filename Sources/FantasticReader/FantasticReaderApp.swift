import SwiftUI
import UniformTypeIdentifiers

@main
struct FantasticReaderApp: App {
    @StateObject private var state = AppState()
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    var body: some Scene {
        WindowGroup("FantasticReader") {
            ContentView().environmentObject(state)
        }
        .defaultSize(width: 1180, height: 760)
    }
}

private let accent = Color(red: 0.76, green: 0.10, blue: 0.14)

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var showImporter = false
    @State private var showPDFOptions = false

    var body: some View {
        VStack(spacing: 0) {
            ribbon
            Divider()
            HSplitView {
                pagesPane.frame(minWidth: 150, idealWidth: 180, maxWidth: 260)
                imagePane.frame(minWidth: 300)
                textPane.frame(minWidth: 300)
            }
            Divider()
            statusBar
        }
        .tint(accent)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { state.add(urls: urls) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    if let d = item as? Data, let u = URL(dataRepresentation: d, relativeTo: nil) {
                        Task { @MainActor in state.add(urls: [u]) }
                    }
                }
            }
            return true
        }
        .sheet(isPresented: $state.showSettings) { SettingsView().environmentObject(state) }
        .onAppear { if state.apiKey.isEmpty { state.showSettings = true } }
    }

    // MARK: Верхняя панель (как в FineReader)
    private var ribbon: some View {
        HStack(spacing: 4) {
            RibbonButton(title: "Открыть", icon: "folder") { showImporter = true }
            RibbonSeparator()
            VStack(spacing: 4) {
                Picker("", selection: $state.engine) {
                    ForEach(OCREngine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .help("Gemini — облако, все языки. Apple Vision — на Mac: русский, украинский, английский и др. Tesseract — на Mac, языки скачиваются в Настройках.")
                Text("Режим распознавания").font(.system(size: 11))
            }
            .padding(.horizontal, 6)
            RibbonSeparator()
            RibbonButton(title: "Распознать", icon: "text.viewfinder",
                         disabled: state.selection == nil || state.busy) { Task { await state.recognizeSelected() } }
            RibbonButton(title: "Распознать все", icon: "doc.text.magnifyingglass",
                         disabled: state.pages.isEmpty || state.busy) { Task { await state.recognizeAll() } }
            RibbonSeparator()
            RibbonButton(title: "В PDF", icon: "doc.richtext", disabled: state.pages.isEmpty) { showPDFOptions = true }
                .popover(isPresented: $showPDFOptions, arrowEdge: .bottom) { pdfOptions }
            RibbonButton(title: "В DOCX", icon: "doc.plaintext",
                         disabled: !state.pages.contains { !$0.text.isEmpty }) { state.saveDOCX() }
            Spacer()
            if state.busy { ProgressView().controlSize(.small).padding(.trailing, 8) }
            RibbonButton(title: "Настройки", icon: "gearshape") { state.showSettings = true }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(LinearGradient(colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                                   startPoint: .top, endPoint: .bottom))
        .overlay(Rectangle().fill(accent).frame(height: 3), alignment: .top)
    }

    private var pdfOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сохранить PDF").font(.headline)
            Picker("", selection: $state.pdfMode) {
                ForEach(PDFMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            Text(state.engine != .gemini
                 ? "Текстовый слой ложится точно на строки изображения."
                 : "С Gemini текстовый слой не привязан к строкам: поиск и копирование работают, выделение — приблизительно.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Шрифт: \(state.fontFamily.isEmpty ? "авто" : state.fontFamily), \(Int(state.fontSize)) pt — меняется в Настройках")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Сохранить…") { showPDFOptions = false; state.savePDF() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16).frame(width: 380)
    }

    // MARK: Страницы
    private var pagesPane: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Страницы")
            List(selection: $state.selection) {
                ForEach(Array(state.pages.enumerated()), id: \.element.id) { idx, p in
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            if let t = p.thumb {
                                Image(nsImage: t).resizable().scaledToFit()
                                    .frame(height: 120)
                                    .shadow(radius: 1.5)
                            }
                            if p.done {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).padding(3)
                            }
                        }
                        Text("\(idx + 1) · \(p.label)").font(.caption).lineLimit(1).truncationMode(.middle)
                    }
                    .tag(p.id)
                    .padding(.vertical, 4)
                    .contextMenu { Button("Удалить") { state.remove(p.id) } }
                }
            }
            .listStyle(.sidebar)
        }
    }

    // MARK: Изображение
    private var imagePane: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Изображение")
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let img = state.preview {
                    GeometryReader { geo in
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: img).resizable().scaledToFit()
                                .frame(width: max(geo.size.width - 24, 100) * state.zoom)
                                .shadow(radius: 3).padding(12)
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 40))
                        Text("Перетащите сюда фото или PDF").font(.callout)
                    }.foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Текст
    private var textPane: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Текст")
            if let i = state.selectedIndex {
                TextEditor(text: Binding(get: { state.pages.indices.contains(i) ? state.pages[i].text : "" },
                                         set: { if state.pages.indices.contains(i) { state.pages[i].text = $0 } }))
                    .font(.system(size: 14))
                    .padding(4)
            } else {
                Color(nsColor: .textBackgroundColor)
            }
        }
    }

    // MARK: Строка состояния
    private var statusBar: some View {
        HStack(spacing: 12) {
            if let e = state.error {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(2)
            } else {
                Text(state.status).foregroundStyle(.secondary)
            }
            Spacer()
            Text(state.engine == .apple ? "Apple Vision · на устройстве" : state.engine == .tesseract ? "Tesseract · \(state.tessLanguages.joined(separator: "+"))" : state.model).font(.caption).foregroundStyle(.secondary)
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $state.zoom, in: 0.5...3).frame(width: 120)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Text("\(Int(state.zoom * 100))%").font(.caption).frame(width: 40, alignment: .trailing)
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RibbonButton: View {
    let title: String
    let icon: String
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 22)).frame(height: 26)
                Text(title).font(.system(size: 11))
            }
            .frame(minWidth: 70).padding(.vertical, 6).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover && !disabled ? accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary : Color.primary)
        .disabled(disabled)
        .onHover { hover = $0 }
    }
}

struct RibbonSeparator: View {
    var body: some View { Divider().frame(height: 40).padding(.horizontal, 4) }
}

struct PanelHeader: View {
    let title: String
    var body: some View {
        HStack { Text(title).font(.system(size: 11, weight: .semibold)); Spacer() }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showLangs = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Настройки").font(.title3.bold())
            Text("Gemini API key").font(.headline)
            SecureField("AIza…", text: $state.apiKey).textFieldStyle(.roundedBorder)
            Text("Ключ хранится в связке ключей macOS. Получить: aistudio.google.com → Get API key.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Модель").font(.headline).padding(.top, 6)
            TextField(GeminiClient.defaultModel, text: $state.model).textFieldStyle(.roundedBorder)
            HStack {
                Button("Загрузить список моделей") { Task { await state.loadModels() } }
                if let st = state.modelsStatus { Text(st).font(.caption).foregroundStyle(.secondary) }
            }
            if !state.availableModels.isEmpty {
                Picker("Выбрать", selection: $state.model) {
                    ForEach(state.availableModels) { m in Text("\(m.title) (\(m.id))").tag(m.id) }
                }
            }
            Text("Название модели в приложении Gemini может отличаться от ID в API. Выбирайте из списка. Для OCR подойдёт любая flash-модель.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Tesseract").font(.headline).padding(.top, 6)
            HStack {
                Button("Языки Tesseract…") { showLangs = true }
                Text(state.tessLanguages.isEmpty ? "языки не выбраны" : state.tessLanguages.joined(separator: " + "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Шрифт для DOCX и PDF").font(.headline).padding(.top, 6)
            HStack {
                Picker("", selection: $state.fontFamily) {
                    Text("Авто (под алфавит текста)").tag("")
                    Divider()
                    ForEach(NSFontManager.shared.availableFontFamilies, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Stepper("\(Int(state.fontSize)) pt", value: $state.fontSize, in: 8...28)
            }
            Text("Образец: Съешь же ещё этих мягких булок · Sample · Օրինակ")
                .font(.custom(state.fontFamily.isEmpty ? "Times New Roman" : state.fontFamily, size: state.fontSize))
                .lineLimit(1)
            Text("Если в выбранном шрифте нет букв нужного языка, Word подставит другой. «Авто» подбирает подходящий сам.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Готово") { state.saveSettings(); state.showSettings = false }
                    .keyboardShortcut(.defaultAction)
            }.padding(.top, 8)
        }
        .padding(20).frame(width: 520)
        .sheet(isPresented: $showLangs) { TesseractLanguagesView().environmentObject(state) }
    }
}

struct TesseractLanguagesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var installed = Tesseract.installed()
    @State private var downloading: Set<String> = []
    @State private var search = ""
    @State private var err: String?

    private var filtered: [Tesseract.Language] {
        Tesseract.allLanguages(installed: installed)
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.code.contains(search.lowercased()) }
            .sorted { (installed.contains($0.code) ? 0 : 1, $0.name) < (installed.contains($1.code) ? 0 : 1, $1.name) }
    }

    private func selected(_ code: String) -> Binding<Bool> {
        Binding(get: { state.tessLanguages.contains(code) },
                set: { on in
                    state.tessLanguages.removeAll { $0 == code }
                    if on { state.tessLanguages.append(code) }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Языки Tesseract").font(.title3.bold())
            if let bin = Tesseract.binary {
                Label("Tesseract найден: \(bin)", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
            } else {
                Label("Tesseract не установлен. В Терминале: brew install tesseract", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Picker("Модели", selection: $state.tessBest) {
                Text("Быстрые (меньше, быстрее)").tag(false)
                Text("Точные (больше, точнее)").tag(true)
            }
            .pickerStyle(.segmented)
            Text("Влияет на новые загрузки. Чтобы сменить уже скачанный язык — удалите и скачайте снова.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Поиск языка", text: $search).textFieldStyle(.roundedBorder)
            List(filtered) { lang in
                HStack {
                    Toggle("", isOn: selected(lang.code)).labelsHidden().toggleStyle(.checkbox)
                        .disabled(!installed.contains(lang.code))
                    Text(lang.name)
                    Text(lang.code).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if downloading.contains(lang.code) {
                        ProgressView().controlSize(.small)
                    } else if installed.contains(lang.code) {
                        Button("Удалить") {
                            Tesseract.delete(lang.code)
                            state.tessLanguages.removeAll { $0 == lang.code }
                            installed = Tesseract.installed()
                        }
                    } else {
                        Button("Скачать") { download(lang.code) }
                    }
                }
            }
            .frame(height: 340)
            HStack {
                Button("Добавить файл .traineddata…") { importFile() }
                Text("например модель Calfa, скачанная вручную").font(.caption).foregroundStyle(.secondary)
            }
            if let err { Text(err).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text("Используются: \(state.tessLanguages.isEmpty ? "—" : state.tessLanguages.joined(separator: " + "))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 540)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "traineddata") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            for u in panel.urls {
                let code = try Tesseract.importModel(from: u)
                if !state.tessLanguages.contains(code) { state.tessLanguages.append(code) }
            }
            installed = Tesseract.installed()
        } catch { err = error.localizedDescription }
    }

    private func download(_ code: String) {
        downloading.insert(code); err = nil
        Task {
            do {
                try await Tesseract.download(code, best: state.tessBest)
                installed = Tesseract.installed()
                if !state.tessLanguages.contains(code) { state.tessLanguages.append(code) }
            } catch { err = error.localizedDescription }
            downloading.remove(code)
        }
    }
}
