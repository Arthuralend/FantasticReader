import Foundation
import Security

/// Хранение API-ключа в связке ключей macOS (а не в коде или файле).
enum Keychain {
    private static let service = "FantasticReader"
    private static let account = "gemini-api-key"

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ value: String) {
        SecItemDelete(baseQuery() as CFDictionary)
        guard !value.isEmpty else { return }
        var q = baseQuery()
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
