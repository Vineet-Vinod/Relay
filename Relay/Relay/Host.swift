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
    var password: String?

    init(
        id: UUID = UUID(),
        name: String,
        hostname: String,
        port: Int = 22,
        username: String,
        password: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
    }
}

extension Host {
    init(peer: PeerDevice, port: Int = 22) {
        self.init(
            name: peer.name,
            hostname: peer.networkAddress,
            port: port,
            username: peer.sshUsername,
            password: peer.sshPassword
        )
    }
}
