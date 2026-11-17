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
    Extract ALL text from this document exactly as written, in its original language(s) and script. \
    Do not translate, summarize or comment. Preserve paragraphs, line breaks, lists and the reading order \
    (including right-to-left scripts). Render tables as tab-separated rows. \
    Output only the extracted text.
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

        let (respData, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GeminiError(message: "Нет ответа от сервера") }
        let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any]

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
