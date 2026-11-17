import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Google Cloud Vision OCR через REST API (images:annotate, DOCUMENT_TEXT_DETECTION).
/// Ключ — из Google Cloud Console (проект с включённым Cloud Vision API).
enum CloudVision {
    static func recognize(cgImage cg: CGImage, apiKey: String, languageHints: [String]) async throws -> (text: String, lines: [OCRLine]) {
        // 1. Изображение → JPEG (не больше 4000 px по длинной стороне)
        let (jpeg, w, h) = try await Task.detached(priority: .userInitiated) { () -> (Data, CGFloat, CGFloat) in
            let scaled = downscale(cg, maxSide: 4000)
            return (try encodeJPEG(scaled), CGFloat(scaled.width), CGFloat(scaled.height))
        }.value

        // 2. Запрос
        var req = URLRequest(url: URL(string: "https://vision.googleapis.com/v1/images:annotate")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var request: [String: Any] = [
            "image": ["content": jpeg.base64EncodedString()],
            "features": [["type": "DOCUMENT_TEXT_DETECTION"]]
        ]
        if !languageHints.isEmpty { request["imageContext"] = ["languageHints": languageHints] }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["requests": [request]])

        // 3. Ответ (с повтором при перегрузке)
        var attempt = 0
        while true {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if [429, 500, 503, 504].contains(status), attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
                continue
            }
            guard status == 200 else {
                throw OCRError(message: "Cloud Vision: " + (((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"))
            }
            guard let r = (json?["responses"] as? [[String: Any]])?.first else { return ("", []) }
            if let e = (r["error"] as? [String: Any])?["message"] as? String { throw OCRError(message: "Cloud Vision: " + e) }
            guard let full = r["fullTextAnnotation"] as? [String: Any] else { return ("", []) }
            return AppleOCR.layout(lines: lines(from: full, width: w, height: h))
        }
    }

    /// pages → blocks → paragraphs → words → symbols. Строки определяются по detectedBreak.
    private static func lines(from full: [String: Any], width w: CGFloat, height h: CGFloat) -> [AppleOCR.Line] {
        var result: [AppleOCR.Line] = []
        var text = ""
        var box: CGRect?

        func flush() {
            let t = text.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, let b = box {
                result.append(AppleOCR.Line(text: t, minX: b.minX / w, maxX: b.maxX / w,
                                            midY: 1 - b.midY / h, h: b.height / h))
            }
            text = ""; box = nil
        }

        for page in full["pages"] as? [[String: Any]] ?? [] {
            for block in page["blocks"] as? [[String: Any]] ?? [] {
                for para in block["paragraphs"] as? [[String: Any]] ?? [] {
                    for word in para["words"] as? [[String: Any]] ?? [] {
                        if let r = rect(word["boundingBox"]) { box = box.map { $0.union(r) } ?? r }
                        for sym in word["symbols"] as? [[String: Any]] ?? [] {
                            text += sym["text"] as? String ?? ""
                            let brk = ((sym["property"] as? [String: Any])?["detectedBreak"] as? [String: Any])?["type"] as? String
                            switch brk {
                            case "SPACE", "SURE_SPACE": text += " "
                            case "HYPHEN": text += "-"; flush()
                            case "EOL_SURE_SPACE", "LINE_BREAK": flush()
                            default: break
                            }
                        }
                    }
                    flush()
                }
            }
        }
        return result
    }

    private static func rect(_ any: Any?) -> CGRect? {
        guard let v = (any as? [String: Any])?["vertices"] as? [[String: Any]], !v.isEmpty else { return nil }
        let xs = v.map { CGFloat(($0["x"] as? NSNumber)?.doubleValue ?? 0) }
        let ys = v.map { CGFloat(($0["y"] as? NSNumber)?.doubleValue ?? 0) }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private static func downscale(_ img: CGImage, maxSide: Int) -> CGImage {
        let side = max(img.width, img.height)
        guard side > maxSide else { return img }
        let k = CGFloat(maxSide) / CGFloat(side)
        let w = Int(CGFloat(img.width) * k), h = Int(CGFloat(img.height) * k)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    private static func encodeJPEG(_ img: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw OCRError(message: "Не удалось подготовить изображение")
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OCRError(message: "Не удалось подготовить изображение") }
        return data as Data
    }
}
