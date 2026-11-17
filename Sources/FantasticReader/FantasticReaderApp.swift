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
        .onAppear { if state.engine == .cloudVision && state.visionKey.isEmpty { state.showSettings = true } }
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
                .pickerStyle(.segmented).labelsHidden().frame(width: 420)
                .help("Google Cloud Vision — облако, много языков (в т.ч. армянский). Apple Vision — на Mac: русский, украинский, английский и др. Tesseract — на Mac, языки скачиваются в Настройках.")
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
            Text("Текстовый слой ложится точно на строки изображения (только из оставленных областей).")
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
            HStack(spacing: 8) {
                Text("Изображение").font(.system(size: 11, weight: .semibold))
                Spacer()
                if state.selectedIndex != nil {
                    Toggle("Области", isOn: $state.showRegions).toggleStyle(.checkbox)
                    Toggle(isOn: $state.drawMode) { Label("Новая область", systemImage: "plus.rectangle") }
                        .toggleStyle(.button)
                        .help("Нарисуйте рамку мышью на изображении")
                    Button { state.deleteSelectedRegion() } label: { Label("Удалить", systemImage: "trash") }
                        .disabled(state.selectedRegion == nil)
                        .help("Удалить выделенную область (или правый клик по рамке → Удалить)")
                    Button { Task { await state.recognizeRegions() } } label: {
                        Label("Распознать области", systemImage: "text.viewfinder")
                    }
                    .disabled(!state.hasPendingRegions || state.busy)
                    .help("Распознать новые (оранжевые) области")
                }
            }
            .font(.system(size: 11))
            .controlSize(.small)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .bottom)
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let img = state.preview {
                    GeometryReader { geo in
                        ScrollView([.horizontal, .vertical]) {
                            Image(nsImage: img).resizable().scaledToFit()
                                .frame(width: max(geo.size.width - 24, 100) * state.zoom)
                                .overlay(GeometryReader { g in
                                    if state.showRegions, let id = state.selection {
                                        RegionOverlay(pageID: id, size: g.size)
                                    }
                                })
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
            Text(state.engine == .apple ? "Apple Vision · на устройстве" : state.engine == .cloudVision ? "Google Cloud Vision" : "Tesseract · \(state.tessLanguages.joined(separator: "+"))").font(.caption).foregroundStyle(.secondary)
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
            Text("Google Cloud Vision").font(.headline)
            SecureField("Ключ Google Cloud Vision API", text: $state.visionKey).textFieldStyle(.roundedBorder)
            TextField("Подсказки языков, напр. hy, ru (пусто — автоопределение)", text: $state.visionHints)
                .textFieldStyle(.roundedBorder)
            Text("Ключ из console.cloud.google.com: включите Cloud Vision API → Credentials → Create API key.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

// MARK: - Области на изображении

enum RegionGeometry {
    /// 0…1 снизу-слева → точки вида сверху-слева
    static func toView(_ r: CGRect, _ s: CGSize) -> CGRect {
        CGRect(x: r.minX * s.width, y: (1 - r.maxY) * s.height, width: r.width * s.width, height: r.height * s.height)
    }
    static func toNorm(_ v: CGRect, _ s: CGSize) -> CGRect {
        CGRect(x: v.minX / s.width, y: 1 - v.maxY / s.height, width: v.width / s.width, height: v.height / s.height)
    }
}

struct RegionOverlay: View {
    @EnvironmentObject var state: AppState
    let pageID: UUID
    let size: CGSize
    @State private var drawStart: CGPoint?
    @State private var drawEnd: CGPoint?

    private var regions: [Region] { state.pages.first { $0.id == pageID }?.regions ?? [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001)
                .frame(width: size.width, height: size.height)
                .onTapGesture { state.selectedRegion = nil }
                .gesture(DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        guard state.drawMode else { return }
                        drawStart = v.startLocation; drawEnd = v.location
                    }
                    .onEnded { _ in
                        if state.drawMode, let a = drawStart, let b = drawEnd {
                            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                            if r.width > 8 && r.height > 8 { state.addRegion(RegionGeometry.toNorm(r, size)) }
                            state.drawMode = false
                        }
                        drawStart = nil; drawEnd = nil
                    })
            ForEach(regions) { r in RegionBox(region: r, size: size) }
            if let a = drawStart, let b = drawEnd {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .foregroundColor(.blue)
                    .frame(width: abs(a.x - b.x), height: abs(a.y - b.y))
                    .position(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

struct RegionBox: View {
    @EnvironmentObject var state: AppState
    let region: Region
    let size: CGSize
    @State private var orig: CGRect?

    enum Corner: CaseIterable, Identifiable {
        case tl, tr, bl, br
        var id: Self { self }
        func point(_ r: CGRect) -> CGPoint {
            switch self {
            case .tl: return CGPoint(x: r.minX, y: r.minY)
            case .tr: return CGPoint(x: r.maxX, y: r.minY)
            case .bl: return CGPoint(x: r.minX, y: r.maxY)
            case .br: return CGPoint(x: r.maxX, y: r.maxY)
            }
        }
        func resize(_ r: CGRect, by t: CGSize) -> CGRect {
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            switch self {
            case .tl: x0 += t.width; y0 += t.height
            case .tr: x1 += t.width; y0 += t.height
            case .bl: x0 += t.width; y1 += t.height
            case .br: x1 += t.width; y1 += t.height
            }
            return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        }
    }

    var body: some View {
        let vr = RegionGeometry.toView(region.rect, size)
        let selected = state.selectedRegion == region.id
        let color: Color = region.needsOCR ? .orange : .green
        ZStack {
            ZStack {
                Rectangle().fill(color.opacity(selected ? 0.18 : 0.07))
                Rectangle().stroke(selected ? Color.blue : color, lineWidth: selected ? 2 : 1.5)
            }
            .frame(width: max(vr.width, 1), height: max(vr.height, 1))
            .contentShape(Rectangle())
            .position(x: vr.midX, y: vr.midY)
            .onTapGesture { state.selectedRegion = region.id }
            .gesture(DragGesture(minimumDistance: 2)
                .onChanged { v in
                    state.selectedRegion = region.id
                    if orig == nil { orig = vr }
                    let o = orig ?? vr
                    state.updateRegion(region.id, rect: RegionGeometry.toNorm(o.offsetBy(dx: v.translation.width, dy: v.translation.height), size))
                }
                .onEnded { _ in orig = nil; state.commitRegion(region.id) })
            .contextMenu {
                Button("Удалить область") { state.deleteRegion(region.id) }
            }

            if selected {
                ForEach(Corner.allCases) { c in
                    Rectangle().fill(Color.white)
                        .overlay(Rectangle().stroke(Color.blue, lineWidth: 1))
                        .frame(width: 9, height: 9)
                        .position(c.point(vr))
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                if orig == nil { orig = vr }
                                let o = orig ?? vr
                                state.updateRegion(region.id, rect: RegionGeometry.toNorm(c.resize(o, by: v.translation), size))
                            }
                            .onEnded { _ in orig = nil; state.commitRegion(region.id) })
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
