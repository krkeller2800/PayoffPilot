//
//  KeychainHelper.swift
//  PayoffPilot
//
//  Created by Assistant on 12/31/25.
//

import Foundation
import Security

/// Minimal Keychain helper for saving, loading, and deleting small secrets like API tokens.
/// Stores values under an account key and returns/accepts plain Strings.
enum KeychainHelper {
    /// Save or replace a secret for the given account key.
    static func save(value: String, for key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        // Remove existing item if present
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain save failed: \(status)"])
        }
    }

    /// Load a secret for the given account key.
    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Delete a secret for the given account key.
    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// Common keys to avoid typos
extension KeychainHelper {
    enum Keys {
        static let tradierToken = "tradier.token"
        static let finnhubToken = "finnhub.token"
        static let polygonToken = "polygon.token"
        static let tradestationToken = "tradestation.token"
    }
}

