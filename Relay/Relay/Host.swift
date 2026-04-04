//
//  Host.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct Host: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var hostname: String
    var port: Int
    var username: String
    var defaultCodexPath: String?
    var authentication: SSHAuthenticationMode
    var transport: HostTransport

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        defaultCodexPath: String? = nil,
        authentication: SSHAuthenticationMode = .automatic,
        transport: HostTransport = .directSSH
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.defaultCodexPath = defaultCodexPath
        self.authentication = authentication
        self.transport = transport
    }
}

extension Host {
    init(
        peer: PeerDevice,
        authentication: SSHAuthenticationMode = .automatic
    ) {
        self.init(
            name: peer.name,
            hostname: peer.meshHostname ?? peer.networkAddress,
            port: peer.port,
            username: peer.sshUsername,
            defaultCodexPath: nil,
            authentication: authentication,
            transport: .directSSH
        )
    }

    var remoteIdentity: SSHRemoteIdentity {
        SSHRemoteIdentity(hostname: hostname, port: port, username: username)
    }

    var endpointIdentity: SSHHostEndpointIdentity {
        SSHHostEndpointIdentity(hostname: hostname, port: port)
    }

    var password: String? {
        authentication.password
    }

    var usesPasswordAuthentication: Bool {
        authentication.usesPassword
    }

    var usesRelayTransport: Bool {
        if case .relay = transport {
            return true
        }

        return false
    }

    var supportsVoiceCodex: Bool {
        !usesRelayTransport
    }

    var savedKeyComment: String {
        "relay-\(username)@\(hostname)"
    }
}
