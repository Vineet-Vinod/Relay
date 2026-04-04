//
//  MeshServiceClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

protocol MeshServiceClient {
    func fetchPeers() async throws -> [PeerDevice]
}

struct MockMeshServiceClient: MeshServiceClient {
    func fetchPeers() async throws -> [PeerDevice] {
        try await Task.sleep(for: .milliseconds(500))
        return AppEnvironment.mockPeers
    }
}
