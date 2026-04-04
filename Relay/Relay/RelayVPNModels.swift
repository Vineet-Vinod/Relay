//
//  RelayVPNModels.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum RelayNetworkPath: String, CaseIterable, Identifiable {
    case relayVPN = "relay-vpn"
    case tailscale
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .relayVPN:
            return "Relay VPN"
        case .tailscale:
            return "Tailscale"
        case .direct:
            return "Direct"
        }
    }

    var detail: String {
        switch self {
        case .relayVPN:
            return "Relay manages the WireGuard tunnel and SSH targets use your Relay VPN addresses."
        case .tailscale:
            return "Relay uses an already-active Tailscale network path. Add devices by Tailscale hostname or IP."
        case .direct:
            return "Relay connects over the current network without a managed mesh tunnel."
        }
    }
}

struct RelayVPNProfileRecord: Codable, Equatable, Sendable {
    let peerIdentifier: String
    let controlServerURL: String
    let assignedAddress: String
    let serverPublicKey: String
    let serverEndpoint: String
    let persistentKeepalive: Int
    let registeredAt: Date

    var displayAssignedAddress: String {
        assignedAddress
    }
}

struct RelayTunnelConfiguration: Codable, Equatable, Sendable {
    let name: String
    let peerIdentifier: String
    let controlServerURL: String
    let clientPrivateKey: String
    let clientAddress: String
    let serverPublicKey: String
    let serverEndpoint: String
    let allowedIPs: [String]
    let persistentKeepalive: Int
}

struct RelayVPNRegistrationRequest: Encodable, Sendable {
    let user_id: String
    let public_key: String
}

struct RelayVPNRegistrationResponse: Decodable, Sendable {
    let assigned_ip: String
    let server_public_key: String
    let server_endpoint: String
    let persistent_keepalive: Int
}

struct RelayServerEndpoint: Equatable, Sendable {
    let host: String
    let port: Int

    init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    init(endpointString: String) throws {
        if endpointString.hasPrefix("["),
           let closingBracketIndex = endpointString.firstIndex(of: "]") {
            let hostStart = endpointString.index(after: endpointString.startIndex)
            let host = String(endpointString[hostStart..<closingBracketIndex])
            let portStart = endpointString.index(after: closingBracketIndex)
            guard portStart < endpointString.endIndex,
                  endpointString[portStart] == ":" else {
                throw RelayVPNError.invalidServerEndpoint
            }

            let rawPort = String(endpointString[endpointString.index(after: portStart)...])
            guard let port = Int(rawPort), (1...65535).contains(port) else {
                throw RelayVPNError.invalidServerEndpoint
            }

            self.init(host: host, port: port)
            return
        }

        guard let lastColon = endpointString.lastIndex(of: ":") else {
            throw RelayVPNError.invalidServerEndpoint
        }

        let host = String(endpointString[..<lastColon])
        let rawPort = String(endpointString[endpointString.index(after: lastColon)...])
        guard !host.isEmpty,
              let port = Int(rawPort),
              (1...65535).contains(port) else {
            throw RelayVPNError.invalidServerEndpoint
        }

        self.init(host: host, port: port)
    }

    var endpointString: String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }

        return "\(host):\(port)"
    }
}

enum RelayVPNPresentationState: Equatable {
    case notConfigured
    case disconnected
    case connecting
    case connected
    case disconnecting
    case invalid
    case error(String)

    var title: String {
        switch self {
        case .notConfigured:
            return "Not Configured"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .disconnecting:
            return "Disconnecting"
        case .invalid:
            return "Unavailable"
        case .error:
            return "Error"
        }
    }

    var detail: String {
        switch self {
        case .notConfigured:
            return "Register this device with your Relay server to install the tunnel profile."
        case .disconnected:
            return "The Relay VPN profile is installed and ready to connect."
        case .connecting:
            return "iOS is starting the Relay VPN tunnel."
        case .connected:
            return "Relay VPN is active and saved devices can use VPN IPs."
        case .disconnecting:
            return "iOS is stopping the Relay VPN tunnel."
        case .invalid:
            return "Relay couldn't load a valid VPN profile from system preferences."
        case .error(let message):
            return message
        }
    }
}

enum RelayVPNError: LocalizedError {
    case invalidControlServerURL
    case invalidServerEndpoint
    case missingTunnelManager
    case missingTunnelConfigurationReference
    case invalidTunnelConfiguration
    case invalidResponse
    case rejectedStatusCode(Int)
    case registrationRequiresHTTPOrHTTPS

    var errorDescription: String? {
        switch self {
        case .invalidControlServerURL:
            return "Enter a valid Relay control server URL."
        case .invalidServerEndpoint:
            return "Relay received an invalid WireGuard server endpoint."
        case .missingTunnelManager:
            return "Relay couldn't find an installed VPN manager."
        case .missingTunnelConfigurationReference:
            return "Relay couldn't locate the stored VPN configuration."
        case .invalidTunnelConfiguration:
            return "Relay couldn't decode the stored VPN configuration."
        case .invalidResponse:
            return "Relay received an unexpected response from the control server."
        case .rejectedStatusCode(let statusCode):
            return "Relay server registration failed with HTTP \(statusCode)."
        case .registrationRequiresHTTPOrHTTPS:
            return "The Relay control server URL must start with http:// or https://."
        }
    }
}

extension RelayDefaultsKey {
    static let preferredNetworkPath = "relay.preferences.preferred-network-path.v1"
    static let relayVPNControlServerURL = "relay.preferences.relay-vpn-control-server-url.v1"
    static let relayVPNPeerIdentifier = "relay.preferences.relay-vpn-peer-identifier.v1"
    static let relayVPNProfileRecord = "relay.preferences.relay-vpn-profile-record.v1"
}
