import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Распознавание через Tesseract (open source, на устройстве).
/// Нужен установленный tesseract: `brew install tesseract`. Языковые модели программа скачивает сама.
enum Tesseract {
    static let candidates = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract", "/opt/local/bin/tesseract", "/usr/bin/tesseract"]
    static var binary: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    /// ~/Library/Application Support/FantasticReader/tessdata
    static var dataDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FantasticReader/tessdata", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func installed() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dataDir.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".traineddata") }.map { String($0.dropLast(".traineddata".count)) })
    }

    static func download(_ code: String, best: Bool) async throws {
        let repo = best ? "tessdata_best" : "tessdata_fast"
        let url = URL(string: "https://github.com/tesseract-ocr/\(repo)/raw/main/\(code).traineddata")!
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GeminiError(message: "Не удалось скачать язык \(code)")
        }
        let dest = dataDir.appendingPathComponent("\(code).traineddata")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func delete(_ code: String) {
        try? FileManager.default.removeItem(at: dataDir.appendingPathComponent("\(code).traineddata"))
    }

    static func recognize(url: URL, pageIndex: Int?, languages: [String]) async throws -> (text: String, lines: [OCRLine]) {
        guard let bin = binary else {
            throw GeminiError(message: "Tesseract не установлен. В Терминале: brew install tesseract")
        }
        let langs = languages.filter { installed().contains($0) }
        guard !langs.isEmpty else {
            throw GeminiError(message: "Не выбраны языки Tesseract: Настройки → Языки Tesseract")
        }
        let dir = dataDir
        return try await Task.detached(priority: .userInitiated) {
            let cg = try orientedImage(url: url, pageIndex: pageIndex)
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("fr-\(UUID().uuidString)")
            let png = base.appendingPathExtension("png")
            let tsv = base.appendingPathExtension("tsv")
            defer { try? FileManager.default.removeItem(at: png); try? FileManager.default.removeItem(at: tsv) }

            guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw GeminiError(message: "Не удалось подготовить изображение")
            }
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = [png.path, base.path, "--tessdata-dir", dir.path, "-l", langs.joined(separator: "+"),
                           "--psm", "3", "-c", "tessedit_create_txt=0", "-c", "tessedit_create_tsv=1"]
            if pageIndex != nil { p.arguments! += ["--dpi", "216"] }
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let out = try? String(contentsOf: tsv, encoding: .utf8) else {
                let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw GeminiError(message: "Tesseract: " + String(msg.suffix(300)))
            }
            return AppleOCR.layout(lines: parseTSV(out, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }.value
    }

    /// Фото с применённым поворотом из EXIF (Tesseract его не учитывает) или страница PDF.
    private static func orientedImage(url: URL, pageIndex: Int?) throws -> CGImage {
        if pageIndex != nil { return try AppleOCR.image(url: url, pageIndex: pageIndex).0 }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 10000]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw GeminiError(message: "Не удалось открыть изображение")
        }
        return cg
    }

    /// TSV Tesseract: слова (level 5) собираются в строки (block, par, line).
    private static func parseTSV(_ tsv: String, width w: CGFloat, height h: CGFloat) -> [AppleOCR.Line] {
        var order: [String] = []
        var words: [String: [(String, CGRect)]] = [:]
        for row in tsv.components(separatedBy: .newlines).dropFirst() {
            let c = row.components(separatedBy: "\t")
            guard c.count >= 12, c[0] == "5",
                  let l = Double(c[6]), let t = Double(c[7]), let ww = Double(c[8]), let hh = Double(c[9]) else { continue }
            let text = c[11...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let key = "\(c[2])-\(c[3])-\(c[4])"
            if words[key] == nil { order.append(key) }
            words[key, default: []].append((text, CGRect(x: l, y: t, width: ww, height: hh)))
        }
        return order.compactMap { key in
            guard let ws = words[key], !ws.isEmpty else { return nil }
            let box = ws.map(\.1).reduce(ws[0].1) { $0.union($1) }
            return AppleOCR.Line(text: ws.map(\.0).joined(separator: " "),
                                 minX: box.minX / w, maxX: box.maxX / w,
                                 midY: 1 - box.midY / h, h: box.height / h)
        }
    }

    // MARK: Список языков tessdata
    struct Language: Identifiable { let code: String; let name: String; var id: String { code } }

    static let languages: [Language] = [
        ("afr","Африкаанс"),("amh","Амхарский"),("ara","Арабский"),("asm","Ассамский"),("aze","Азербайджанский"),
        ("aze_cyrl","Азербайджанский (кириллица)"),("bel","Белорусский"),("ben","Бенгальский"),("bod","Тибетский"),
        ("bos","Боснийский"),("bre","Бретонский"),("bul","Болгарский"),("cat","Каталанский"),("ceb","Себуанский"),
        ("ces","Чешский"),("chi_sim","Китайский упрощённый"),("chi_sim_vert","Китайский упрощённый (верт.)"),
        ("chi_tra","Китайский традиционный"),("chi_tra_vert","Китайский традиционный (верт.)"),("chr","Чероки"),
        ("cos","Корсиканский"),("cym","Валлийский"),("dan","Датский"),("deu","Немецкий"),("div","Мальдивский"),
        ("dzo","Дзонг-кэ"),("ell","Греческий"),("eng","Английский"),("enm","Среднеанглийский"),("epo","Эсперанто"),
        ("est","Эстонский"),("eus","Баскский"),("fao","Фарерский"),("fas","Персидский"),("fil","Филиппинский"),
        ("fin","Финский"),("fra","Французский"),("frk","Немецкий фрактур"),("frm","Среднефранцузский"),
        ("fry","Западнофризский"),("gla","Гэльский"),("gle","Ирландский"),("glg","Галисийский"),
        ("grc","Древнегреческий"),("guj","Гуджарати"),("hat","Гаитянский"),("heb","Иврит"),("hin","Хинди"),
        ("hrv","Хорватский"),("hun","Венгерский"),("hye","Армянский"),("iku","Инуктитут"),("ind","Индонезийский"),
        ("isl","Исландский"),("ita","Итальянский"),("ita_old","Староитальянский"),("jav","Яванский"),
        ("jpn","Японский"),("jpn_vert","Японский (верт.)"),("kan","Каннада"),("kat","Грузинский"),
        ("kat_old","Старогрузинский"),("kaz","Казахский"),("khm","Кхмерский"),("kir","Киргизский"),
        ("kmr","Курманджи"),("kor","Корейский"),("lao","Лаосский"),("lat","Латынь"),("lav","Латышский"),
        ("lit","Литовский"),("ltz","Люксембургский"),("mal","Малаялам"),("mar","Маратхи"),("mkd","Македонский"),
        ("mlt","Мальтийский"),("mon","Монгольский"),("mri","Маори"),("msa","Малайский"),("mya","Бирманский"),
        ("nep","Непальский"),("nld","Нидерландский"),("nor","Норвежский"),("oci","Окситанский"),("ori","Ория"),
        ("pan","Панджаби"),("pol","Польский"),("por","Португальский"),("pus","Пушту"),("que","Кечуа"),
        ("ron","Румынский"),("rus","Русский"),("san","Санскрит"),("sin","Сингальский"),("slk","Словацкий"),
        ("slv","Словенский"),("snd","Синдхи"),("spa","Испанский"),("spa_old","Староиспанский"),("sqi","Албанский"),
        ("srp","Сербский (кириллица)"),("srp_latn","Сербский (латиница)"),("sun","Сунданский"),("swa","Суахили"),
        ("swe","Шведский"),("syr","Сирийский"),("tam","Тамильский"),("tat","Татарский"),("tel","Телугу"),
        ("tgk","Таджикский"),("tha","Тайский"),("tir","Тигринья"),("ton","Тонганский"),("tur","Турецкий"),
        ("uig","Уйгурский"),("ukr","Украинский"),("urd","Урду"),("uzb","Узбекский"),("uzb_cyrl","Узбекский (кириллица)"),
        ("vie","Вьетнамский"),("yid","Идиш"),("yor","Йоруба")
    ].map { Language(code: $0.0, name: $0.1) }
}
