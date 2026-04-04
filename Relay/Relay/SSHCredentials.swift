//
//  SSHCredentials.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

@preconcurrency import Crypto
import Foundation
import NIOSSH
import Security

struct SSHRemoteIdentity: Hashable, Codable {
    let hostname: String
    let port: Int
    let username: String

    var storageKey: String {
        "\(hostname.lowercased()):\(port):\(username.lowercased())"
    }
}

struct SSHHostEndpointIdentity: Hashable, Codable {
    let hostname: String
    let port: Int

    var storageKey: String {
        "\(hostname.lowercased()):\(port)"
    }
}

enum SSHAuthenticationMode: Hashable, Codable {
    case automatic
    case password(String)

    var usesPassword: Bool {
        if case .password = self {
            return true
        }

        return false
    }

    var password: String? {
        guard case .password(let password) = self else {
            return nil
        }

        return password
    }
}

struct SSHStoredKeyMetadata: Codable, Hashable {
    let keychainTag: String
    let publicKey: String
    let createdAt: Date
}

struct SSHStoredKeyRecord: Identifiable, Hashable {
    let id: String
    let remote: SSHRemoteIdentity
    let metadata: SSHStoredKeyMetadata
}

struct TrustedSSHHostKey: Codable, Hashable {
    let algorithm: String
    let base64Payload: String
    let fingerprint: String
    let firstSeenAt: Date
}

struct TrustedSSHHostRecord: Identifiable, Hashable {
    let id: String
    let endpoint: SSHHostEndpointIdentity
    let hostKey: TrustedSSHHostKey
}

struct SSHGeneratedKeyPair: Sendable {
    let privateKey: Curve25519.Signing.PrivateKey
    let publicKey: SSHPublicKeyPayload
    let comment: String

    static func generate(comment: String) -> SSHGeneratedKeyPair {
        let privateKey = Curve25519.Signing.PrivateKey()
        return SSHGeneratedKeyPair(
            privateKey: privateKey,
            publicKey: .ed25519(privateKey.publicKey),
            comment: comment
        )
    }

    var authorizedKey: String {
        publicKey.openSSHLine(comment: comment)
    }

    var nioPrivateKey: NIOSSHPrivateKey {
        NIOSSHPrivateKey(ed25519Key: privateKey)
    }
}

struct SSHPublicKeyPayload: Codable, Hashable, Sendable {
    let algorithm: String
    let base64Payload: String

    nonisolated var wireData: Data {
        Data(base64Encoded: base64Payload) ?? Data()
    }

    nonisolated var fingerprint: String {
        let digest = Data(SHA256.hash(data: wireData))
        return "SHA256:\(digest.base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "=")))"
    }

    nonisolated func openSSHLine(comment: String? = nil) -> String {
        guard let comment, !comment.isEmpty else {
            return "\(algorithm) \(base64Payload)"
        }

        return "\(algorithm) \(base64Payload) \(comment)"
    }

    nonisolated static func ed25519(_ key: Curve25519.Signing.PublicKey) -> SSHPublicKeyPayload {
        SSHPublicKeyPayload(
            algorithm: "ssh-ed25519",
            base64Payload: SSHWireEncoder.ed25519(publicKey: key).base64EncodedString()
        )
    }

    nonisolated static func ecdsaP256(_ key: P256.Signing.PublicKey) -> SSHPublicKeyPayload {
        SSHPublicKeyPayload(
            algorithm: "ecdsa-sha2-nistp256",
            base64Payload: SSHWireEncoder.ecdsa(
                algorithm: "ecdsa-sha2-nistp256",
                curveName: "nistp256",
                publicKeyBytes: key.rawRepresentation
            ).base64EncodedString()
        )
    }

    nonisolated static func ecdsaP384(_ key: P384.Signing.PublicKey) -> SSHPublicKeyPayload {
        SSHPublicKeyPayload(
            algorithm: "ecdsa-sha2-nistp384",
            base64Payload: SSHWireEncoder.ecdsa(
                algorithm: "ecdsa-sha2-nistp384",
                curveName: "nistp384",
                publicKeyBytes: key.rawRepresentation
            ).base64EncodedString()
        )
    }

    nonisolated static func ecdsaP521(_ key: P521.Signing.PublicKey) -> SSHPublicKeyPayload {
        SSHPublicKeyPayload(
            algorithm: "ecdsa-sha2-nistp521",
            base64Payload: SSHWireEncoder.ecdsa(
                algorithm: "ecdsa-sha2-nistp521",
                curveName: "nistp521",
                publicKeyBytes: key.rawRepresentation
            ).base64EncodedString()
        )
    }

    nonisolated static func hostKey(_ key: NIOSSHPublicKey) throws -> SSHPublicKeyPayload {
        let mirror = Mirror(reflecting: key)
        guard let backingKey = mirror.children.first?.value else {
            throw SSHClientError.unsupportedHostKey
        }

        let backingMirror = Mirror(reflecting: backingKey)
        guard let reflectedKey = backingMirror.children.first?.value else {
            throw SSHClientError.unsupportedHostKey
        }

        switch reflectedKey {
        case let key as Curve25519.Signing.PublicKey:
            return .ed25519(key)
        case let key as P256.Signing.PublicKey:
            return .ecdsaP256(key)
        case let key as P384.Signing.PublicKey:
            return .ecdsaP384(key)
        case let key as P521.Signing.PublicKey:
            return .ecdsaP521(key)
        default:
            throw SSHClientError.unsupportedHostKey
        }
    }
}

final class SSHCredentialStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let keyMetadataDefaultsKey = "relay.ssh.keyMetadata.v1"
    private let trustedHostsDefaultsKey = "relay.ssh.trustedHosts.v1"
    private let dismissedSetupDefaultsKey = "relay.ssh.dismissedKeySetup.v1"
    private let keychainService: String

    init(defaults: UserDefaults = .standard, keychainService: String? = nil) {
        self.defaults = defaults
        self.keychainService = keychainService
            ?? "\(Bundle.main.bundleIdentifier ?? "rybkr.Relay").ssh.privateKey"
    }

    nonisolated func storedKeyMetadata(for remote: SSHRemoteIdentity) -> SSHStoredKeyMetadata? {
        lock.withLock {
            keyMetadata()[remote.storageKey]
        }
    }

    nonisolated func hasStoredKey(for remote: SSHRemoteIdentity) -> Bool {
        (try? privateKey(for: remote)) != nil
    }

    nonisolated func privateKey(for remote: SSHRemoteIdentity) throws -> NIOSSHPrivateKey? {
        guard let metadata = storedKeyMetadata(for: remote) else {
            return nil
        }

        guard let privateKeyData = try loadKeychainData(tag: metadata.keychainTag) else {
            clearStoredKeyRecord(for: remote, tag: metadata.keychainTag)
            return nil
        }

        do {
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            return NIOSSHPrivateKey(ed25519Key: privateKey)
        } catch {
            clearStoredKeyRecord(for: remote, tag: metadata.keychainTag)
            return nil
        }
    }

    nonisolated func save(_ keyPair: SSHGeneratedKeyPair, for remote: SSHRemoteIdentity) throws {
        let tag = keychainTag(for: remote)
        try saveKeychainData(keyPair.privateKey.rawRepresentation, tag: tag)
        let metadata = SSHStoredKeyMetadata(
            keychainTag: tag,
            publicKey: keyPair.authorizedKey,
            createdAt: Date()
        )

        lock.withLock {
            var metadataMap = keyMetadata()
            metadataMap[remote.storageKey] = metadata
            saveKeyMetadata(metadataMap)

            var dismissed = dismissedSetupPrompts()
            dismissed.remove(remote.storageKey)
            saveDismissedSetupPrompts(dismissed)
        }
    }

    nonisolated func removeStoredKey(for remote: SSHRemoteIdentity) {
        let tag = storedKeyMetadata(for: remote)?.keychainTag ?? keychainTag(for: remote)
        clearStoredKeyRecord(for: remote, tag: tag)
    }

    nonisolated func storedKeyRecords() -> [SSHStoredKeyRecord] {
        lock.withLock {
            keyMetadata()
                .compactMap { storageKey, metadata in
                    guard let remote = SSHRemoteIdentity(storageKey: storageKey) else {
                        return nil
                    }

                    return SSHStoredKeyRecord(
                        id: storageKey,
                        remote: remote,
                        metadata: metadata
                    )
                }
                .sorted { lhs, rhs in
                    lhs.remote.storageKey.localizedCaseInsensitiveCompare(rhs.remote.storageKey) == .orderedAscending
                }
        }
    }

    nonisolated func removeAllStoredKeys() {
        let records = storedKeyRecords()
        for record in records {
            clearStoredKeyRecord(for: record.remote, tag: record.metadata.keychainTag)
        }
    }

    nonisolated func trustedHostKey(for endpoint: SSHHostEndpointIdentity) -> TrustedSSHHostKey? {
        lock.withLock {
            trustedHosts()[endpoint.storageKey]
        }
    }

    nonisolated func saveTrustedHostKey(_ hostKey: TrustedSSHHostKey, for endpoint: SSHHostEndpointIdentity) {
        lock.withLock {
            var hosts = trustedHosts()
            hosts[endpoint.storageKey] = hostKey
            saveTrustedHosts(hosts)
        }
    }

    nonisolated func trustedHostRecords() -> [TrustedSSHHostRecord] {
        lock.withLock {
            trustedHosts()
                .compactMap { storageKey, hostKey in
                    guard let endpoint = SSHHostEndpointIdentity(storageKey: storageKey) else {
                        return nil
                    }

                    return TrustedSSHHostRecord(
                        id: storageKey,
                        endpoint: endpoint,
                        hostKey: hostKey
                    )
                }
                .sorted { lhs, rhs in
                    lhs.endpoint.storageKey.localizedCaseInsensitiveCompare(rhs.endpoint.storageKey) == .orderedAscending
                }
        }
    }

    nonisolated func removeTrustedHostKey(for endpoint: SSHHostEndpointIdentity) {
        lock.withLock {
            var hosts = trustedHosts()
            hosts.removeValue(forKey: endpoint.storageKey)
            saveTrustedHosts(hosts)
        }
    }

    nonisolated func removeAllTrustedHostKeys() {
        lock.withLock {
            saveTrustedHosts([:])
        }
    }

    nonisolated func shouldOfferKeySetup(for remote: SSHRemoteIdentity) -> Bool {
        guard !hasStoredKey(for: remote) else {
            return false
        }

        return lock.withLock {
            !dismissedSetupPrompts().contains(remote.storageKey)
        }
    }

    nonisolated func dismissKeySetupPrompt(for remote: SSHRemoteIdentity) {
        lock.withLock {
            var dismissed = dismissedSetupPrompts()
            dismissed.insert(remote.storageKey)
            saveDismissedSetupPrompts(dismissed)
        }
    }

    nonisolated func resetDismissedKeySetupPrompts() {
        lock.withLock {
            saveDismissedSetupPrompts(Set<String>())
        }
    }

    nonisolated func eraseAllData() {
        removeAllStoredKeys()
        removeAllTrustedHostKeys()
        resetDismissedKeySetupPrompts()
    }

    private func keychainTag(for remote: SSHRemoteIdentity) -> String {
        "\(keychainService).\(remote.storageKey)"
    }

    private func keyMetadata() -> [String: SSHStoredKeyMetadata] {
        decode([String: SSHStoredKeyMetadata].self, forKey: keyMetadataDefaultsKey) ?? [:]
    }

    private func saveKeyMetadata(_ value: [String: SSHStoredKeyMetadata]) {
        encode(value, forKey: keyMetadataDefaultsKey)
    }

    private func trustedHosts() -> [String: TrustedSSHHostKey] {
        decode([String: TrustedSSHHostKey].self, forKey: trustedHostsDefaultsKey) ?? [:]
    }

    private func saveTrustedHosts(_ value: [String: TrustedSSHHostKey]) {
        encode(value, forKey: trustedHostsDefaultsKey)
    }

    private func dismissedSetupPrompts() -> Set<String> {
        decode(Set<String>.self, forKey: dismissedSetupDefaultsKey) ?? []
    }

    private func saveDismissedSetupPrompts(_ value: Set<String>) {
        encode(value, forKey: dismissedSetupDefaultsKey)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }

        defaults.set(data, forKey: key)
    }

    private func loadKeychainData(tag: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return nil
        }

        guard status == errSecSuccess else {
            throw SSHClientError.keychainFailure(status: status)
        }

        return item as? Data
    }

    private func saveKeychainData(_ data: Data, tag: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tag,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw SSHClientError.keychainFailure(status: updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SSHClientError.keychainFailure(status: addStatus)
        }
    }

    private func deleteKeychainData(tag: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tag,
        ]

        SecItemDelete(query as CFDictionary)
    }

    private func clearStoredKeyRecord(for remote: SSHRemoteIdentity, tag: String) {
        deleteKeychainData(tag: tag)

        lock.withLock {
            var metadataMap = keyMetadata()
            metadataMap.removeValue(forKey: remote.storageKey)
            saveKeyMetadata(metadataMap)

            var dismissed = dismissedSetupPrompts()
            dismissed.remove(remote.storageKey)
            saveDismissedSetupPrompts(dismissed)
        }
    }
}

private enum SSHWireEncoder {
    static func ed25519(publicKey: Curve25519.Signing.PublicKey) -> Data {
        sshString("ssh-ed25519") + sshString(publicKey.rawRepresentation)
    }

    static func ecdsa(algorithm: String, curveName: String, publicKeyBytes: Data) -> Data {
        sshString(algorithm) + sshString(curveName) + sshString(publicKeyBytes)
    }

    private static func sshString(_ string: String) -> Data {
        sshString(Data(string.utf8))
    }

    private static func sshString(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var encoded = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        encoded.append(data)
        return encoded
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer {
            unlock()
        }
        return body()
    }
}

private extension SSHRemoteIdentity {
    init?(storageKey: String) {
        let components = storageKey.split(separator: ":", maxSplits: 2).map(String.init)
        guard components.count == 3, let port = Int(components[1]) else {
            return nil
        }

        self.init(hostname: components[0], port: port, username: components[2])
    }
}

private extension SSHHostEndpointIdentity {
    init?(storageKey: String) {
        let components = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2, let port = Int(components[1]) else {
            return nil
        }

        self.init(hostname: components[0], port: port)
    }
}
