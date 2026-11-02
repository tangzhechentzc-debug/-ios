import Foundation
import Security

@MainActor
final class PairingVault {
    private let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.tzchen.ChangeLocation.pairing",
        kSecAttrAccount as String: "this-iphone"
    ]

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let record = String(data: data, encoding: .utf8) else {
            throw LocationFailure(message: "无法读取本机配对记录，请解锁 iPhone 后重试。")
        }
        return record
    }

    func save(_ record: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(record.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw LocationFailure(message: "配对完成，但无法保存至本机钥匙串。请重试配对。")
        }
    }
}
