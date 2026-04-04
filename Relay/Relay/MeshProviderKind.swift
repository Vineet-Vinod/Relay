//
//  MeshProviderKind.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

enum MeshProviderKind: String, CaseIterable, Identifiable, Codable {
    case tailscale
    case relay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tailscale:
            return "Tailscale"
        case .relay:
            return "Relay"
        }
    }

    var detail: String {
        switch self {
        case .tailscale:
            return "Connect directly to Tailscale hosts over SSH."
        case .relay:
            return "Connect through your Relay HTTPS server and macOS agent."
        }
    }
}

enum MeshProviderFactory {
    @MainActor
    static func makeProvider(for kind: MeshProviderKind) -> any MeshProvider {
        switch kind {
        case .tailscale:
            return ManualDeviceProvider()
        case .relay:
            return RelayMeshProvider()
        }
    }
}
