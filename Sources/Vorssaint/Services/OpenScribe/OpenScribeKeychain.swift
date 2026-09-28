// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

/// API keys for OpenScribe endpoints, one generic password per endpoint id.
/// Keys never enter preferences, so a settings backup or a shared defaults
/// dump cannot carry them. The service name follows the bundle id, keeping
/// the Developer build's keys apart from the released app's.
enum OpenScribeKeychain {
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.vorssaint.utils") + ".openscribe"
    }

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func key(for id: UUID) -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func hasKey(for id: UUID) -> Bool {
        var request = query(id)
        request[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    /// An empty key removes the stored one.
    @discardableResult
    static func setKey(_ key: String, for id: UUID) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            removeKey(for: id)
            return true
        }
        let data = Data(trimmed.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query(id)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = "Vorssaint OpenScribe API key"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func removeKey(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }

    /// Self-uninstall takes every OpenScribe key with it.
    static func removeAll() {
        let request: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service]
        SecItemDelete(request as CFDictionary)
    }
}
