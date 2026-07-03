import Foundation
import Security

/// 安全存储 API Key
class SecureKeyStorage {
    static let shared = SecureKeyStorage()
    
    private let service = "com.moss.Spoken"
    private let legacyAccount = "minimax_api_key"
    private let account = "llm_api_key"
    private let speechAccount = "speech_api_key"
    private let speechBackupKey = "speech_api_key_backup"
    
    private init() {}
    
    /// 读取 LLM API Key（先读新 account，兼容旧 account）
    func readAPIKey() -> String? {
        // 先尝试读取新的 account
        if let key = readKey(forAccount: account), !key.isEmpty {
            return key
        }
        // 回退读取旧的 account（向后兼容）
        if let key = readKey(forAccount: legacyAccount), !key.isEmpty {
            return key
        }
        return nil
    }
    
    /// 读取语音识别 API Key
    /// 由于 ad-hoc 签名每次构建会变化，Keychain 可能读取失败，因此同时维护 UserDefaults 备份
    func readSpeechAPIKey() -> String? {
        if let key = readKey(forAccount: speechAccount), !key.isEmpty {
            return key
        }
        // Keychain 读取失败时，回退到 UserDefaults 备份
        return UserDefaults.standard.string(forKey: speechBackupKey)
    }
    
    private func readKey(forAccount acc: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        return key
    }
    
    /// 保存 LLM API Key（保存到新 account，空值时删除）
    func saveAPIKey(_ key: String) -> Bool {
        return saveKey(key, forAccount: account)
    }
    
    /// 保存语音识别 API Key
    /// 同时保存到 Keychain 和 UserDefaults 备份，避免 ad-hoc 签名变化导致读取失败
    func saveSpeechAPIKey(_ key: String) -> Bool {
        UserDefaults.standard.set(key, forKey: speechBackupKey)
        return saveKey(key, forAccount: speechAccount)
    }
    
    private func saveKey(_ key: String, forAccount acc: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        guard !key.isEmpty, let data = key.data(using: .utf8) else {
            return true
        }
        
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// 删除 LLM API Key（同时删除新旧 account）
    func deleteAPIKey() {
        for acc in [account, legacyAccount] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: acc
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}
