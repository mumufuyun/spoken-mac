import Foundation
import Security

/// 安全存储 API Key
class SecureKeyStorage {
    static let shared = SecureKeyStorage()
    
    private let service = "com.moss.Spoken"
    private let legacyAccount = "minimax_api_key"
    private let account = "llm_api_key"
    
    private init() {}
    
    /// 读取 API Key（先读新 account，兼容旧 account）
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
    
    /// 保存 API Key（保存到新 account，空值时删除）
    func saveAPIKey(_ key: String) -> Bool {
        // 先删除新 account 的旧数据
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 空值不保存，直接返回成功（已删除）
        guard !key.isEmpty, let data = key.data(using: .utf8) else {
            return true
        }
        
        // 添加新的
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// 删除 API Key（同时删除新旧 account）
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
