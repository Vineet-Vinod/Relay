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
    var transportMode: SSHTransportMode
    var authentication: SSHAuthenticationMode

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        transportMode: SSHTransportMode = .real,
        authentication: SSHAuthenticationMode = .automatic
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.transportMode = transportMode
        self.authentication = authentication
    }
}

extension Host {
    init(
        peer: PeerDevice,
        transportMode: SSHTransportMode = .real,
        authentication: SSHAuthenticationMode = .automatic,
        port: Int = 22
    ) {
        self.init(
            name: peer.name,
            hostname: peer.meshHostname ?? peer.networkAddress,
            port: port,
            username: peer.sshUsername,
            transportMode: transportMode,
            authentication: authentication
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

    var savedKeyComment: String {
        "relay-\(username)@\(hostname)"
    }
}
