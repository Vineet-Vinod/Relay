//
//  RelayTunnelProviderConfiguration.swift
//  RelayTunnelExtension
//
//  Created by Codex on 4/4/26.
//

import Foundation
import NetworkExtension
import Security
import WireGuardKit

struct RelayTunnelProviderConfiguration: Decodable {
    let name: String
    let peerIdentifier: String
    let controlServerURL: String
    let clientPrivateKey: String
    let clientAddress: String
    let serverPublicKey: String
    let serverEndpoint: String
    let allowedIPs: [String]
    let persistentKeepalive: Int

    static func load(from protocolConfiguration: NETunnelProviderProtocol?) throws -> RelayTunnelProviderConfiguration {
        guard let protocolConfiguration else {
            throw RelayTunnelProviderError.invalidProtocolConfiguration
        }

        guard let persistentReference = protocolConfiguration.passwordReference else {
            throw RelayTunnelProviderError.missingStoredConfiguration
        }

        return try RelayTunnelProviderKeychain.loadConfiguration(from: persistentReference)
    }

    func makeWireGuardConfiguration() throws -> TunnelConfiguration {
        guard let privateKey = PrivateKey(base64Key: clientPrivateKey) else {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }

        guard let publicKey = PublicKey(base64Key: serverPublicKey) else {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }

        guard let interfaceAddress = IPAddressRange(from: "\(clientAddress)/24") else {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }

        guard let endpoint = Endpoint(from: serverEndpoint) else {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }

        let parsedAllowedIPs = allowedIPs.compactMap(IPAddressRange.init(from:))
        guard parsedAllowedIPs.count == allowedIPs.count else {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }

        var interfaceConfiguration = InterfaceConfiguration(privateKey: privateKey)
        interfaceConfiguration.addresses = [interfaceAddress]

        var peerConfiguration = PeerConfiguration(publicKey: publicKey)
        peerConfiguration.allowedIPs = parsedAllowedIPs
        peerConfiguration.endpoint = endpoint
        peerConfiguration.persistentKeepAlive = UInt16(clamping: persistentKeepalive)

        return TunnelConfiguration(
            name: name,
            interface: interfaceConfiguration,
            peers: [peerConfiguration]
        )
    }
}

enum RelayTunnelProviderError: LocalizedError {
    case invalidProtocolConfiguration
    case missingStoredConfiguration
    case invalidStoredConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidProtocolConfiguration:
            return "Relay tunnel provider received an invalid tunnel protocol configuration."
        case .missingStoredConfiguration:
            return "Relay tunnel provider could not find the stored tunnel configuration."
        case .invalidStoredConfiguration:
            return "Relay tunnel provider could not decode the stored tunnel configuration."
        }
    }
}

enum RelayTunnelProviderKeychain {
    static func loadConfiguration(from persistentReference: Data) throws -> RelayTunnelProviderConfiguration {
        let query: [CFString: Any] = [
            kSecValuePersistentRef: persistentReference,
            kSecReturnData: true,
            kSecClass: kSecClassGenericPassword,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw RelayTunnelProviderError.missingStoredConfiguration
        }

        guard let data = item as? Data else {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }

        do {
            return try JSONDecoder().decode(RelayTunnelProviderConfiguration.self, from: data)
        } catch {
            throw RelayTunnelProviderError.invalidStoredConfiguration
        }
    }
}
