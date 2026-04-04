//
//  RelayTunnelKeychain.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import Security

enum RelayTunnelKeychainError: LocalizedError {
    case storeFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case invalidPersistentReference
    case invalidStoredData

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Relay couldn't store the VPN configuration in the Keychain. (\(status))"
        case .loadFailed(let status):
            return "Relay couldn't load the VPN configuration from the Keychain. (\(status))"
        case .deleteFailed(let status):
            return "Relay couldn't remove the VPN configuration from the Keychain. (\(status))"
        case .invalidPersistentReference:
            return "Relay couldn't create a persistent reference for the VPN configuration."
        case .invalidStoredData:
            return "Relay found invalid VPN configuration data in the Keychain."
        }
    }
}

enum RelayTunnelKeychain {
    private static let service = "rybkr.Relay.relay-vpn"

    static func storeConfiguration(_ configuration: RelayTunnelConfiguration) throws -> Data {
        let encodedConfiguration = try JSONEncoder().encode(configuration)
        let account = configuration.peerIdentifier
        let query = baseQuery(account: account)

        let updateAttributes: [CFString: Any] = [
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel: "Relay VPN \(configuration.name)",
            kSecValueData: encodedConfiguration,
        ]

        let existingStatus = SecItemCopyMatching(query as CFDictionary, nil)
        switch existingStatus {
        case errSecSuccess:
            let updateStatus = SecItemUpdate(
                query as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw RelayTunnelKeychainError.storeFailed(updateStatus)
            }
        case errSecItemNotFound:
            var addQuery = query
            updateAttributes.forEach { addQuery[$0.key] = $0.value }

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw RelayTunnelKeychainError.storeFailed(addStatus)
            }
        default:
            throw RelayTunnelKeychainError.storeFailed(existingStatus)
        }

        var persistentReference: CFTypeRef?
        var referenceQuery = query
        referenceQuery[kSecReturnPersistentRef] = true
        let referenceStatus = SecItemCopyMatching(
            referenceQuery as CFDictionary,
            &persistentReference
        )
        guard referenceStatus == errSecSuccess else {
            throw RelayTunnelKeychainError.storeFailed(referenceStatus)
        }

        guard let data = persistentReference as? Data else {
            throw RelayTunnelKeychainError.invalidPersistentReference
        }

        return data
    }

    static func loadConfiguration(from persistentReference: Data) throws -> RelayTunnelConfiguration {
        let query: [CFString: Any] = [
            kSecValuePersistentRef: persistentReference,
            kSecReturnData: true,
            kSecClass: kSecClassGenericPassword,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw RelayTunnelKeychainError.loadFailed(status)
        }

        guard let data = item as? Data else {
            throw RelayTunnelKeychainError.invalidStoredData
        }

        do {
            return try JSONDecoder().decode(RelayTunnelConfiguration.self, from: data)
        } catch {
            throw RelayVPNError.invalidTunnelConfiguration
        }
    }

    static func deleteConfiguration(peerIdentifier: String) throws {
        let status = SecItemDelete(baseQuery(account: peerIdentifier) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RelayTunnelKeychainError.deleteFailed(status)
        }
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
