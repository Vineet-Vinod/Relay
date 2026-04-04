//
//  AppEnvironment.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum AppEnvironment {
    static let defaultMeshProviderMode: MeshProviderMode = .mock

    // Replace these with the real device addresses and usernames. The password
    // is entered by the user at connection time.
    static let mockPeers: [PeerDevice] = [
        PeerDevice(
            providerIdentifier: "preview-macbook",
            name: "macbook",
            networkAddress: "10.186.120.143",
            meshHostname: "macbook.tailnet.ts.net",
            sshUsername: "ryanbaker",
            isOnline: true,
            operatingSystem: "macOS",
            ownerName: "Ryan Baker"
        ),
        PeerDevice(
            providerIdentifier: "preview-iphone",
            name: "RB iPhone",
            networkAddress: "10.186.138.156",
            meshHostname: "rb-iphone.tailnet.ts.net",
            sshUsername: "mobile",
            isOnline: true,
            operatingSystem: "iOS",
            ownerName: "Ryan Baker"
        ),
    ]
}
