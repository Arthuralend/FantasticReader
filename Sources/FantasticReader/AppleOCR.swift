import AppKit
import PDFKit
import Vision
import ImageIO

/// Распознавание на устройстве через Apple Vision: без интернета и без ключа.
/// Подходит для русского, украинского, английского и других языков, которые поддерживает macOS.
enum AppleOCR {
    static let preferredLanguages = ["ru-RU", "uk-UA", "en-US"]

    static func recognize(url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let pages = try images(from: url).map { try recognize(image: $0.0, orientation: $0.1) }
            return pages.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }.value
    }

    // MARK: Загрузка изображений (фото с учётом поворота из EXIF, PDF — все страницы)
    private static func images(from url: URL) throws -> [(CGImage, CGImagePropertyOrientation)] {
        if url.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw GeminiError(message: "Не удалось открыть PDF") }
            return (0..<doc.pageCount).compactMap { i in
                guard let page = doc.page(at: i) else { return nil }
                let b = page.bounds(for: .mediaBox)
                let img = page.thumbnail(of: CGSize(width: b.width * 3, height: b.height * 3), for: .mediaBox)
                guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                return (cg, .up)
            }
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw GeminiError(message: "Не удалось открыть изображение")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return [(cg, CGImagePropertyOrientation(rawValue: raw) ?? .up)]
    }

    private static func recognize(image: CGImage, orientation: CGImagePropertyOrientation) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        let supported = (try? req.supportedRecognitionLanguages()) ?? []
        let langs = preferredLanguages.filter { supported.contains($0) }
        if !langs.isEmpty { req.recognitionLanguages = langs }
        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([req])
        return layout(req.results ?? [])
    }

    // MARK: Сборка строк в абзацы
    private struct Line { var text: String; var minX, maxX, midY, h: CGFloat }

    private static func median(_ v: [CGFloat]) -> CGFloat {
        let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
    }

    private static func layout(_ obs: [VNRecognizedTextObservation]) -> String {
        // Vision: координаты 0…1, начало снизу слева
        let items = obs.compactMap { o -> Line? in
            guard let t = o.topCandidates(1).first?.string else { return nil }
            let b = o.boundingBox
            return Line(text: t, minX: b.minX, maxX: b.maxX, midY: b.midY, h: b.height)
        }.sorted { $0.midY > $1.midY }

        // Фрагменты на одной высоте — одна строка
        var lines: [Line] = []
        for it in items {
            if var last = lines.last, abs(last.midY - it.midY) < min(last.h, it.h) * 0.5 {
                last.text = last.minX <= it.minX ? last.text + " " + it.text : it.text + " " + last.text
                last.minX = min(last.minX, it.minX); last.maxX = max(last.maxX, it.maxX)
                lines[lines.count - 1] = last
            } else { lines.append(it) }
        }
        guard !lines.isEmpty else { return "" }

        let left = median(lines.map(\.minX))
        let right = lines.map(\.maxX).sorted()[Int(Double(lines.count - 1) * 0.9)]
        let lineH = median(lines.map(\.h))
        let blockCenter = (left + right) / 2

        var out: [String] = []
        var cur = ""
        var prev: Line?
        var prevVerse = false
        func flush() { if !cur.isEmpty { out.append(cur); cur = "" } }

        for l in lines {
            let indent = l.minX - left
            let width = l.maxX - l.minX
            let centered = abs((l.minX + l.maxX) / 2 - blockCenter) < 0.04 && width < (right - left) * 0.6 && indent > 0.05

            if centered {
                flush(); out.append("# " + l.text); prev = l; prevVerse = false; continue
            }
            if indent > 0.2 { // строки, сдвинутые далеко вправо: стихи, эпиграфы
                flush()
                if prevVerse, let last = out.last { out[out.count - 1] = last + "\n> " + l.text }
                else { out.append("> " + l.text) }
                prev = l; prevVerse = true; continue
            }
            var newPara = cur.isEmpty
            if let p = prev {
                if p.midY - l.midY > lineH * 2.2 { newPara = true }   // большой интервал
                if p.maxX < right - 0.1 { newPara = true }            // предыдущая строка короткая
                if prevVerse { newPara = true }
            }
            if indent > 0.015 { newPara = true }                      // красная строка
            if let f = l.text.first, "-—–".contains(f) { newPara = true } // реплика диалога

            if newPara { flush(); cur = l.text }
            else if cur.hasSuffix("-"), cur.dropLast().last?.isLetter == true {
                cur = String(cur.dropLast()) + l.text                 // убираем перенос
            } else { cur += " " + l.text }
            prev = l; prevVerse = false
        }
        flush()
        return out.joined(separator: "\n\n")
    }
}
