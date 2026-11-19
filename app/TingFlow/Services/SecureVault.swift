import Foundation
import Security

/// Device-local credentials. Never UserDefaults, logs, analytics or script storage.
enum SecureVault {
    private static let service = "com.ikamio.tingflow.credentials.v1"
    static func save(_ data: Data, key: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key]
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            for (k, v) in changes { item[k] = v }
            let inserted = SecItemAdd(item as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw VaultError(status: inserted) }
        } else if status != errSecSuccess { throw VaultError(status: status) }
    }
    static func read(key: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw VaultError(status: status) }
        return data
    }
    static func remove(key: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status: status) }
    }
    private struct VaultError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "设备凭据存储不可用（\(status)），请解锁设备后重试。" }
    }
}
