//
//  PeerDevice.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct PeerDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let networkAddress: String
    let sshUsername: String
    let isOnline: Bool
    let operatingSystem: String
    let ownerName: String

    init(
        id: UUID = UUID(),
        name: String,
        networkAddress: String,
        sshUsername: String,
        isOnline: Bool,
        operatingSystem: String,
        ownerName: String
    ) {
        self.id = id
        self.name = name
        self.networkAddress = networkAddress
        self.sshUsername = sshUsername
        self.isOnline = isOnline
        self.operatingSystem = operatingSystem
        self.ownerName = ownerName
    }
}
