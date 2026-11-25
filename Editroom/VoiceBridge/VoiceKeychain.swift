import Foundation
import Security

/// Reads and stores API keys (`OPENAI_API_KEY`, `XAI_API_KEY`) from environment or macOS Keychain.
/// Never logs or persists any secret in source code, logs, or project files.
enum VoiceKeychain {
    enum Provider: String, CaseIterable {
        case openai
        case xai

        var envName: String {
            switch self {
            case .openai: return "OPENAI_API_KEY"
            case .xai: return "XAI_API_KEY"
            }
        }

        var serviceNames: [String] {
            switch self {
            case .openai: return ["OPENAI_API_KEY", "openai_api_key", "com.editroom.openai-api-key"]
            case .xai: return ["XAI_API_KEY", "xai_api_key", "com.editroom.xai-api-key"]
            }
        }
    }

    static func loadAPIKey(for provider: Provider) -> String? {
        if let env = ProcessInfo.processInfo.environment[provider.envName]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        for service in provider.serviceNames {
            if let key = readKeychain(service: service), !key.isEmpty {
                return key
            }
        }
        return nil
    }

    @discardableResult
    static func saveAPIKey(_ key: String, for provider: Provider) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        let service = provider.serviceNames[0]
        let account = NSUserName()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func readKeychain(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return value
    }
}
