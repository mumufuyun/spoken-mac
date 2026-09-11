import Foundation
import Security

/// 安全存储 API Key
final class SecureKeyStorage: ConnectionKeyStore, @unchecked Sendable {
    static let shared = SecureKeyStorage()
    
    private let service = "com.moss.Spoken"
    private let legacyAccount = "minimax_api_key"
    private let account = "llm_api_key"
    private let speechAccount = "speech_api_key"
    private let legacySpeechBackupKey = "speech_api_key_backup"
    
    private init() {}

    func readCredential(_ id: String) throws -> String? {
        try readChecked(account: "llm_connection_\(id)")
    }

    func readLegacyCredential() throws -> String? {
        if let key = try readChecked(account: account), !key.isEmpty { return key }
        return try readChecked(account: legacyAccount)
    }

    private func readChecked(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ConfigurationError.unavailable("无法读取钥匙串，请解锁后重试（\(status)）")
        }
        return key
    }

    func writeCredential(_ key: String, id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "llm_connection_\(id)",
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ConfigurationError.unavailable("密钥未保存，请解锁钥匙串后重试（\(status)）")
        }
    }

    func removeCredential(_ id: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "llm_connection_\(id)"]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.unavailable("无法删除钥匙串中的密钥（\(status)）")
        }
    }
    
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
    
    /// 读取语音识别 API Key。密钥只保存在 Keychain。
    func readSpeechCredential() throws -> String? {
        try readChecked(account: speechAccount)
    }

    func readSpeechAPIKey() -> String? {
        // 清理旧版曾经保存在 UserDefaults 中的明文备份。
        UserDefaults.standard.removeObject(forKey: legacySpeechBackupKey)
        if let key = readKey(forAccount: speechAccount), !key.isEmpty {
            return key
        }
        return nil
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
    func saveSpeechAPIKey(_ key: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: legacySpeechBackupKey)
        return saveKey(key, forAccount: speechAccount)
    }

    func deleteSpeechAPIKey() {
        UserDefaults.standard.removeObject(forKey: legacySpeechBackupKey)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: speechAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
    
    private func saveKey(_ key: String, forAccount acc: String) -> Bool {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acc
        ]
        guard !key.isEmpty, let data = key.data(using: .utf8) else {
            let status = SecItemDelete(deleteQuery as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let updateStatus = SecItemUpdate(deleteQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        
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
