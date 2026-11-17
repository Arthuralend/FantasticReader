import Foundation

struct GeminiError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Распознавание текста через Gemini API (REST). Язык определяется автоматически,
/// поддерживаются все языки, которые понимает модель.
struct GeminiClient {
    let apiKey: String
    // Модель можно сменить в настройках приложения, если Google выпустит новую.
    static let defaultModel = "gemini-3.8-flash"
    var model = GeminiClient.defaultModel

    private let prompt = """
    Transcribe ALL text from this document in its original language(s) and script. \
    Do not translate, summarize or add comments. Output only the text.

    Rebuild clean, readable text instead of copying the physical line layout of the page:
    - Join lines that belong to the same paragraph into ONE line. Remove end-of-line hyphenation \
    (join the two halves of the word without the hyphen).
    - Separate paragraphs with exactly one empty line. Never use spaces or tabs for indentation or alignment.
    - Write letter-spaced words normally (e.g. "W O R D" -> "WORD").
    - Omit purely decorative character runs (like ",,,,," or "*****" used as ornaments).
    - Titles and headings: start the line with "# ".
    - Poems, epigraphs and other text where line breaks matter: keep each verse on its own line \
    and start EVERY such line with "> ".
    - Keep dialogue dashes and punctuation as in the original. Tables: tab-separated rows.
    """

    func recognize(data: Data, mimeType: String) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": ["mime_type": mimeType, "data": data.base64EncodedString()]]
                ]
            ]],
            "generationConfig": ["temperature": 0]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (respData, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw GeminiError(message: "Нет ответа от сервера") }
            let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]

            // Модель перегружена или лимит запросов: ждём и повторяем (4, 8, 12 … секунд)
            if [429, 500, 503, 504].contains(http.statusCode), attempt < 4 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 4_000_000_000)
                continue
            }
            guard http.statusCode == 200 else {
                let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
                throw GeminiError(message: msg)
            }
            let candidates = json?["candidates"] as? [[String: Any]]
            let parts = (candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
            let text = parts?.compactMap { $0["text"] as? String }.joined() ?? ""
            guard !text.isEmpty else { throw GeminiError(message: "Текст не найден или ответ заблокирован") }
            return text
        }
    }

    /// Список моделей, доступных вашему ключу и умеющих generateContent.
    static func listModels(apiKey: String) async throws -> [ModelInfo] {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=200")!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw GeminiError(message: ((json?["error"] as? [String: Any])?["message"] as? String) ?? "Не удалось получить список моделей")
        }
        let models = json?["models"] as? [[String: Any]] ?? []
        return models.compactMap { m in
            guard let name = m["name"] as? String, name.contains("gemini"),
                  (m["supportedGenerationMethods"] as? [String])?.contains("generateContent") == true else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            return ModelInfo(id: id, title: (m["displayName"] as? String) ?? id)
        }
    }
}

struct ModelInfo: Identifiable, Hashable {
    let id: String
    let title: String
}
