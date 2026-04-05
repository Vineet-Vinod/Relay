//
//  RelayConfigurationStore.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Security

final class RelayConfigurationStore: @unchecked Sendable {
    static let shared = RelayConfigurationStore()

    private let defaults: UserDefaults
    private let registrationKeychainAccount = "relay-app-registration"
    private let lock = NSLock()
    private let keychainService: String

    init(defaults: UserDefaults = .standard, keychainService: String? = nil) {
        self.defaults = defaults
        self.keychainService = keychainService
            ?? "\(Bundle.main.bundleIdentifier ?? "rybkr.Relay").relay.registration"
    }

    func configuredServerURL() -> URL? {
        lock.withLock {
            guard let rawValue = defaults.string(forKey: RelayDefaultsKey.relayServerURL)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty,
                  let url = URL(string: rawValue),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http" else {
                return nil
            }

            return url
        }
    }

    func allowsInsecureTLS() -> Bool {
        lock.withLock {
            defaults.object(forKey: RelayDefaultsKey.relayAllowInsecureTLS) as? Bool ?? false
        }
    }

    func selectedProviderKind() -> MeshProviderKind {
        lock.withLock {
            guard let rawValue = defaults.string(forKey: RelayDefaultsKey.meshProviderKind),
                  let kind = MeshProviderKind(rawValue: rawValue) else {
                return .tailscale
            }

            return kind
        }
    }

    func registration() -> RelayAppRegistration? {
        lock.withLock {
            guard let data = loadKeychainData(account: registrationKeychainAccount) else {
                return nil
            }

            return try? JSONDecoder().decode(RelayAppRegistration.self, from: data)
        }
    }

    func saveRegistration(_ registration: RelayAppRegistration) throws {
        let data = try JSONEncoder().encode(registration)
        try lock.withLock {
            try? deleteKeychainItem(account: registrationKeychainAccount)
            try storeKeychainData(data, account: registrationKeychainAccount)
        }
    }

    func clearRegistration() {
        lock.withLock {
            try? deleteKeychainItem(account: registrationKeychainAccount)
        }
    }

    private func loadKeychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    private func storeKeychainData(_ data: Data, account: String) throws {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw SSHClientError.keychainFailure(status: status)
        }
    }

    private func deleteKeychainItem(account: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(deleteQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SSHClientError.keychainFailure(status: status)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
