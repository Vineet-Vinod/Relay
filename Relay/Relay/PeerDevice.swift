//
//  PeerDevice.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct PeerDevice: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let providerIdentifier: String
    let name: String
    let networkAddress: String
    let meshHostname: String?
    let port: Int
    let sshUsername: String
    let isOnline: Bool
    let operatingSystem: String
    let ownerName: String

    init(
        id: UUID = UUID(),
        providerIdentifier: String = UUID().uuidString,
        name: String,
        networkAddress: String,
        meshHostname: String? = nil,
        port: Int = 22,
        sshUsername: String,
        isOnline: Bool,
        operatingSystem: String,
        ownerName: String
    ) {
        self.id = id
        self.providerIdentifier = providerIdentifier
        self.name = name
        self.networkAddress = networkAddress
        self.meshHostname = meshHostname
        self.port = port
        self.sshUsername = sshUsername
        self.isOnline = isOnline
        self.operatingSystem = operatingSystem
        self.ownerName = ownerName
    }
}

extension PeerDevice {
    var displayAddress: String {
        meshHostname ?? networkAddress
    }
}
