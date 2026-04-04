//
//  AppEnvironment.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum AppEnvironment {
    static let sshTransportMode: SSHTransportMode = .real

    // Replace these with the real SSH credentials for the Mac you want the
    // phone to connect to. The address must be reachable from the phone.
    static let mockPeers: [PeerDevice] = [
        PeerDevice(
            name: "macbook",
            networkAddress: "10.186.120.143",
            sshUsername: "ryanbaker",
            sshPassword: "REPLACE_WITH_MAC_PASSWORD",
            isOnline: true,
            operatingSystem: "macOS",
            ownerName: "Ryan Baker"
        ),
        PeerDevice(
            name: "RB iPhone",
            networkAddress: "10.186.138.156",
            sshUsername: "mobile",
            isOnline: true,
            operatingSystem: "iOS",
            ownerName: "Ryan Baker"
        ),
    ]
}
