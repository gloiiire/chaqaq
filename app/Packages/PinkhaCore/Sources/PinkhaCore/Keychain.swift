import Foundation
import Security

/// Minimal Keychain wrapper for storing short-lived secrets (API tokens, OAuth
/// access tokens) tied to a single device. All entries use
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never synced to iCloud.
public enum Keychain {

    /// Account key prefix to avoid collisions with other apps sharing the same
    /// access group. Each call site picks its own suffix (e.g. "notion.token").
    private static let service = "com.gloiiire.pinkha"

    /// Persist `value` under `key`. Overwrites any previous entry.
    /// Returns `true` on success. Logs but does not throw on failure — the
    /// caller can fall back to in-memory storage transparently.
    @discardableResult
    public static func save(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     key,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        // Try to update first; if no entry exists, fall back to add.
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            for (k, v) in attributes { addQuery[k] = v }
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Read the value previously stored under `key`, or `nil` if absent.
    public static func load(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Remove the entry for `key`. No-op if it does not exist.
    @discardableResult
    public static func remove(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Keys used by Pinkha. Defined here so call sites cannot typo them.
public enum KeychainKey {
    /// Notion integration token (`secret_xxx…`) entered manually by the user.
    public static let notionToken = "notion.token"
}
